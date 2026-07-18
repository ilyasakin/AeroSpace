import AppKit
import Common

@MainActor
var resizeWithMouseTask: Task<(), any Error>? = nil

/// Noise floor for edge diffs / size-change detection (floating precision + layout vs WS lag).
let mouseResizeNoiseThreshold: CGFloat = 5

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        guard let window else { return }

        let mouseResize: Bool
        do {
            mouseResize = try await isManipulatedWithMouse(window)
        } catch {
            return
        }

        if !mouseResize {
            // Non-drag resize (app-driven): drop frame caches and rediscover/layout.
            (window as? MacWindow)?.invalidateAxFrameCaches()
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }

        // Mouse-drag resize: keep lastAppliedLayoutPhysicalRect — it is the *layout baseline*
        // compared against the live AX/WS frame to compute weight diffs. Invalidating it here
        // made every drag tick early-return (diff baseline was always nil).
        currentlyManipulatedWithMouseWindowId = window.windowId
        // Edge resize often also fires AXMoved; cancel a racing move task that would wipe the baseline.
        moveWithMouseTask?.cancel()
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        for workspace in Workspace.allUnsorted {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

/// Whether mouse-resize can compute weight diffs: needs a layout baseline and a live frame.
/// Pure helper so tests lock the invariant that invalidating lastApplied before drag breaks resize.
func resizeWithMouseCanApplyDiffs(lastApplied: Rect?, live: Rect?) -> Bool {
    lastApplied != nil && live != nil
}

/// True when the live frame's size differs from the layout baseline — user is resizing, not
/// title-bar reordering. AX often emits both Moved and Resized for edge/corner drags; the move
/// path must not clear lastApplied or swap tiles in that case.
func isMouseResizeLikeDrag(lastApplied: Rect?, live: Rect?, threshold: CGFloat = mouseResizeNoiseThreshold) -> Bool {
    guard let lastApplied, let live else { return false }
    return abs(lastApplied.width - live.width) > threshold
        || abs(lastApplied.height - live.height) > threshold
}

/// Live on-screen frame for mouse-resize weight diffs.
/// Never returns `lastApplied` — that rect is the *baseline* compared against the live frame.
/// Prefers WindowServer overlay bounds (not gated on `skylight-reads`); falls back to AX.
@MainActor
func liveRectForMouseResize(_ window: Window) async throws -> Rect? {
    if let bounds = WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true) {
        return bounds
    }
    if let mac = window as? MacWindow {
        // Bypass MacWindow.getAxRect's resolveFrameRead path, which prefers lastApplied when
        // framesWrittenThisSession is set (write-lag guard). That would make live == baseline.
        return try await mac.macApp.getAxRect(mac.windowId, .cancellable)
    }
    return try await window.getAxRect(.cancellable)
}

@MainActor
func resizeWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .unbound: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            // Live frame (WS/AX). Baseline must remain lastApplied from layout — do not invalidate it
            // on the mouse-drag path (see resizedObs / moveTilingWindow guards).
            guard let rect = try await liveRectForMouseResize(window) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            assert(
                resizeWithMouseCanApplyDiffs(lastApplied: lastAppliedLayoutRect, live: rect),
                "mouse resize requires layout baseline + live frame",
            )
            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0
                    && abs(diff) > mouseResizeNoiseThreshold
                {
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
