import AppKit
import Common

@MainActor
var moveWithMouseTask: Task<(), any Error>? = nil

/// Frame notifications already queued for the kernel, per window and kind. Each one is handled by
/// reading the window's frame when it runs, so while one is waiting, more of the same add nothing:
/// a busy kernel used to run a dozen identical copies back to back (each judged on its own, each
/// able to schedule a refresh)
@MainActor var queuedFrameNotifications: Set<String> = []

@MainActor func takeFrameNotificationSlot(_ windowId: UInt32, _ kind: String) -> Bool {
    queuedFrameNotifications.insert("\(kind)/\(windowId)").inserted
}

@MainActor func releaseFrameNotificationSlot(_ windowId: UInt32, _ kind: String) {
    queuedFrameNotifications.remove("\(kind)/\(windowId)")
}

func onAxWindowMoved(windowId: UInt32?, notif: String) {
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        guard let window, takeFrameNotificationSlot(window.windowId, "moved") else { return }
        await Kernel.exclusive("ax moved") {
            releaseFrameNotificationSlot(window.windowId, "moved")
            guard Window.get(byId: window.windowId) != nil else { return }
            // Our own layout write coming back: nothing to learn, no drag to start (an echo during an
            // unrelated mouse-down used to be mistaken for a user drag and rewrite weights)
            let report: FrameRecord.Report = currentlyManipulatedWithMouseWindowId == window.windowId
                ? .external : window.judgeFrameNotification()
            if report == .lagging { scheduleLagRecheck(window.windowId, notif) }
            if report != .external {
                FrameTrace.log("echo-moved \(window.windowId) live=\(fmt(WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)))")
                return
            }
            FrameTrace.log("external-moved \(window.windowId) live=\(fmt(WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)))")

            let mouseMove: Bool
            do {
                mouseMove = try await isManipulatedWithMouse(window)
            } catch {
                return
            }

            if !mouseMove {
                window.noteExternalFrameChange()
                scheduleCancellableCompleteRefreshSession(.ax(notif))
                return
            }

            let continuingDrag = currentlyManipulatedWithMouseWindowId == window.windowId
            // Stamp before light plan so session skips side-UI rebuild + follow-up heavy.
            currentlyManipulatedWithMouseWindowId = window.windowId
            // Floating free-drag: start display-Hz border sampling *before* the light session Task,
            // so the first frames aren't waiting on session scheduling / AX.
            if window.isFloating {
                FloatingBorderTracker.kick(window)
                // Mid-drag, a float only needs the tree touched when it crosses onto another monitor's
                // workspace. A light session per AX tick (focus sync, layout, tray) kept the main
                // thread busy, and the display-link sampler — one pulse in flight, stalls skip frames —
                // dropped border frames: the ring trailed the window.
                if continuingDrag, mouseLocation.monitorApproximation.activeWorkspace == window.nodeWorkspace {
                    return
                }
            }
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
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    WindowMemory.forgetWorld()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            // Edge resize changes size and origin; AX emits Moved + Resized. Do not clear
            // belief or swap tiles — that is resize-with-mouse's job.
            // Size check uses drag-start baseline when set (belief tracks live layout mid-resize).
            let live = try await liveRectForMouseResize(window)
            let inResizeGesture = currentlyManipulatedWithMouseWindowId == window.windowId
                && mouseResizePhysicalBaselineIfSet(for: window) != nil
            let sizeBaseline = mouseResizePhysicalBaselineIfSet(for: window)
                ?? window.knownFrame
            if inResizeGesture || isMouseResizeLikeDrag(believed: sizeBaseline, live: live) {
                ensureMouseResizeWindowServerNotifications(for: window)
                MouseResizeDriver.kick(window)
                return
            }
            moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) {
    // Arm display-Hz border sampler first (before any tree work) so the border tracks at
    // monitor refresh even when the rest of the light session is busy.
    FloatingBorderTracker.kick(window)

    // Mouse location is free; AX getCenter every drag tick serialized the main actor and
    // delayed border paint by many frames. During a title-bar drag the pointer is on the window.
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    guard window.parent != nil else { return }
    // Compare against the window's WORKSPACE, not its parent. `window.parent` during a float drag
    // is the FloatingWindowsContainer; comparing a Workspace to it went through TreeNode's identity
    // `==` and was therefore ALWAYS true, so every AX moved tick rebound the window — reordering it
    // to the end of the floating container and pushing MRU up the whole chain each frame, which
    // corrupts the float z-order that click and focus-follows-mouse hit-testing read.
    if targetWorkspace != window.nodeWorkspace {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    // Drag ownership is expressed ONLY by this stamp — layout checks it (`mouseTarget`) and skips
    // the AX write for the dragged window, and the border frame resolver reads it to track live
    // bounds. This used to also nil the frame slot to "free the layout baseline",
    // which never worked: layout unconditionally rewrites that field on the very next tick (it
    // must, so sibling borders share one coherent frame). Two writers, one of them ineffective.
    currentlyManipulatedWithMouseWindowId = window.windowId
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let swapTarget = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.desiredRect {
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
                    effectiveHitRect($0, virtual: virtual)?.contains(point) == true
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

/// Hit-test rect for a tiling child.
///
/// Layout now assigns container rects (see `assignContainerRects`), so this is normally a plain
/// read. The descendant-union fallback remains for the window between a materialize (which
/// rebuilds containers, clearing their geometry) and the next layout pass — without it, a
/// drag landing in that window would find no target over a nested split.
@MainActor
private func effectiveHitRect(_ node: TreeNode, virtual: Bool) -> Rect? {
    if let own = virtual ? node.lastAppliedLayoutVirtualRect : node.desiredRect {
        return own
    }
    guard node is TilingContainer else { return nil }
    var acc: Rect? = nil
    for child in node.children {
        guard let r = effectiveHitRect(child, virtual: virtual) else { continue }
        acc = acc.map { existing in
            let minX = min(existing.topLeftX, r.topLeftX)
            let minY = min(existing.topLeftY, r.topLeftY)
            let maxX = max(existing.topLeftX + existing.width, r.topLeftX + r.width)
            let maxY = max(existing.topLeftY + existing.height, r.topLeftY + r.height)
            return Rect(topLeftX: minX, topLeftY: minY, width: maxX - minX, height: maxY - minY)
        } ?? r
    }
    return acc
}

/// A frame notification that looked like WindowServer lag gets one more look once the lag window
/// is over: an app restoring its own saved frame right after we placed it looks exactly like lag
/// at first, and swallowing it left the window at its own frame with nothing to rewrite it.
@MainActor
func scheduleLagRecheck(_ windowId: UInt32, _ notif: String) {
    Task.startUnstructured { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64((FrameRecord.windowServerLagSeconds + 0.1) * 1_000_000_000))
        await Kernel.exclusive("frame lag recheck") {
            guard let window = Window.get(byId: windowId), window.recheckAfterLag() else { return }
            FrameTrace.log("lag-recheck \(windowId) was the app's own frame")
            window.noteExternalFrameChange()
            scheduleCancellableCompleteRefreshSession(.ax(notif))
        }
    }
}
