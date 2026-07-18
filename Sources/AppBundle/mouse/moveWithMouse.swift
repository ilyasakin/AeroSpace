import AppKit
import Common

@MainActor
var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        guard let window else { return }

        let mouseMove: Bool
        do {
            mouseMove = try await isManipulatedWithMouse(window)
        } catch {
            return
        }

        if !mouseMove {
            (window as? MacWindow)?.invalidateAxFrameCaches()
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }

        // Stamp before light plan so session skips side-UI rebuild + follow-up heavy.
        currentlyManipulatedWithMouseWindowId = window.windowId
        // Edge/corner resize also fires AXMoved. Route those to resize so we never wipe the
        // layout baseline or tile-swap mid-resize (see isMouseResizeLikeDrag).
        resizeWithMouseTask?.cancel()
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            // Edge resize changes size and origin; AX emits Moved + Resized. Do not clear
            // lastApplied or swap tiles — that is resize-with-mouse's job.
            // Size check uses drag-start baseline when set (lastApplied tracks live layout mid-resize).
            let live = try await liveRectForMouseResize(window)
            let inResizeGesture = currentlyManipulatedWithMouseWindowId == window.windowId
                && mouseResizePhysicalBaselineIfSet(for: window) != nil
            let sizeBaseline = mouseResizePhysicalBaselineIfSet(for: window)
                ?? window.lastAppliedLayoutPhysicalRect
            if inResizeGesture || isMouseResizeLikeDrag(lastApplied: sizeBaseline, live: live) {
                ensureMouseResizeWindowServerNotifications(for: window)
                MouseResizeDriver.kick(window)
                return
            }
            moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    // Title-bar drag only: free the layout baseline so layout does not fight the drag visual.
    // Must not run for resize-like drags (caller routes those to resizeWithMouse).
    window.lastAppliedLayoutPhysicalRect = nil
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let swapTarget = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect {
            mouseLocation.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? swapTarget.ownIndex.orDie() + 1
                : swapTarget.ownIndex.orDie()
        } else {
            0
        }
        window.bind(
            to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let swapTarget {
        swapWindows(mruDominant: window, swapTarget)
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    // Prefer path-copy commit when both are tiling leaves on the same workspace
    if let ws = window1.nodeWorkspace,
       ws === window2.nodeWorkspace,
       window1.parent is TilingContainer,
       window2.parent is TilingContainer,
       ws.commitTilingSwap(id1: window1.windowId, id2: window2.windowId)
    {
        return
    }

    // Fallback: dual-link swap (different workspaces / non-tiling)
    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles, .master:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
