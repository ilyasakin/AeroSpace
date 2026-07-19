import AppKit
import ApplicationServices

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
/// Last window id we successfully focused via FFM — cheap skip without full tree focus lookup.
@MainActor private var focusFollowsLastFocusedId: UInt32? = nil
@MainActor private var focusFollowsLastPoint: CGPoint = .init(x: -1, y: -1)

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        focusFollowsLastFocusedId = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor _ in
        let location = mouseLocation
        // Ignore sub-pixel jitter / tiny moves that still spam mouseMoved.
        let dx = location.x - focusFollowsLastPoint.x
        let dy = location.y - focusFollowsLastPoint.y
        if dx * dx + dy * dy < 2.25 { // < 1.5pt
            return
        }
        focusFollowsLastPoint = location

        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()

            // Z-order-aware geometry (CGWindowList front-to-back). Floating windows that sit
            // above tiles must win even when the cursor is over the tile's layout rect —
            // otherwise nativeFocus raises the tile and the float "jumps" to the bottom.
            guard let window = windowUnderMouseCheap(location) else {
                try checkCancellation()
                if await isAxWindowUnderMouse(location) == false { return }
                guard let window = try await windowUnderMouseAxFallback(location) else { return }
                try await focusFollowsApply(window, token: token)
                return
            }

            // Already focused — zero session work (hot path while moving inside a window).
            if window.windowId == focusFollowsLastFocusedId
                || window.windowId == focus.windowOrNil?.windowId
            {
                focusFollowsLastFocusedId = window.windowId
                return
            }

            // Menu / desktop filter only when we are about to change focus.
            try checkCancellation()
            if await isAxWindowUnderMouse(location) == false { return }

            try await focusFollowsApply(window, token: token)
        }
    }
}

@MainActor
private func focusFollowsApply(_ window: Window, token: RunSessionGuard) async throws {
    try checkCancellation()
    try await runLightSession(.focusFollowsMouse, token) {
        // Tree focus first; nativeFocusRespectingFloats is the only OS focus write (pipeline
        // skips end-of-session nativeFocus for FFM — must not re-raise and undo raise:false).
        _ = window.focusWindow()
        window.nativeFocusRespectingFloats()
    }
    // FFM light sessions skip sideUiBorders — still move active border style/occlusion.
    WindowBordersManager.shared.syncActiveFocus()
    focusFollowsLastFocusedId = window.windowId
}

/// Geometry hit test. Floating windows always beat tiles they cover (live frame), then
/// front-to-back stack, then tiling layout rects.
@MainActor
func windowUnderMouseCheap(_ location: CGPoint) -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace

    // 1) Floats first using live/lastApplied frames — independent of stale CGWindowList cache.
    //    Treat any float containing the point as above the tiling layer for hit purposes.
    for child in workspace.floatingWindowsContainer.mruChildren {
        guard let child = child as? Window else { continue }
        if floatingWindowFrame(child)?.contains(location) == true {
            return child
        }
    }

    // 2) Front-to-back stack among remaining candidates (fresh each call when floats exist).
    if !workspace.floatingWindows.isEmpty {
        invalidateOnScreenWindowSnapshot()
    }
    let stack = onScreenWindowSnapshot().normalStack
    for item in stack {
        guard item.rect.contains(location) else { continue }
        guard let window = Window.get(byId: item.id) else { continue }
        guard windowIsEligibleForFfm(window, on: workspace) else { continue }
        // Floats already handled above; skip so we don't re-hit with stale stack order.
        if window.isFloating { continue }
        return window
    }

    // 3) Tiling layout rects (lastApplied / virtual).
    if let w = location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: false,
        fullscreenCoversAll: true,
    ) {
        return w
    }
    return location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: true,
        fullscreenCoversAll: true,
    )
}

@MainActor
private func windowIsEligibleForFfm(_ window: Window, on workspace: Workspace) -> Bool {
    if window.isHiddenInCorner { return false }
    if window.nodeWorkspace == workspace { return true }
    // Sticky floats/tiles follow the monitor's active workspace.
    if window.isSticky, window.nodeMonitor?.activeWorkspace == workspace { return true }
    return false
}

/// Live or last-known frame for a floating window (layout clears lastApplied on some paths).
@MainActor
func floatingWindowFrame(_ window: Window) -> Rect? {
    if let applied = window.lastAppliedLayoutPhysicalRect ?? window.lastAppliedLayoutVirtualRect {
        return applied
    }
    return WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
}

/// AX rect scan — only when cheap geometry found nothing.
@MainActor
private func windowUnderMouseAxFallback(_ location: CGPoint) async throws -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace
    // Prefer front-to-back among floats that actually contain the point (live AX rect).
    for child in workspace.floatingWindowsContainer.mruChildren {
        try checkCancellation()
        guard let child = child as? Window else { continue }
        guard let rect = try await child.getAxRect(.cancellable) else { continue }
        if rect.contains(location) { return child }
    }
    for w in workspace.allLeafWindowsRecursive {
        try checkCancellation()
        guard let rect = try await w.getAxRect(.cancellable) else { continue }
        if rect.contains(location) { return w }
    }
    return nil
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }

    var pid: pid_t = 0
    if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
        return nil
    }

    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}
