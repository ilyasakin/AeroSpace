import AppKit
import ApplicationServices

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor _ in
        // Prefer the shared mouseLocation helper (same coord system as layout rects / monitors).
        let location = mouseLocation
        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // Overlay panels (status bar / tab bar / borders) are our pid — treated as nil, not false.
            // AX re-enters AppKit hitTest off MainActor; overlay hitTest is nonisolated to avoid SIGTRAP.
            if await isAxWindowUnderMouse(location) == false { return }
            try checkCancellation()

            guard let window = try await windowUnderMouse(location) else { return }
            // Same window already focused — skip a redundant session.
            if window.windowId == focus.windowOrNil?.windowId { return }
            try checkCancellation()
            try await runLightSession(.focusFollowsMouse, token) {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
    }
}

/// Resolve the AeroSpace-managed window under `location` (AeroSpace top-left coords).
@MainActor
private func windowUnderMouse(_ location: CGPoint) async throws -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace

    // Floating (MRU order)
    for child in workspace.floatingWindowsContainer.mruChildren {
        try checkCancellation()
        guard let child = child as? Window else { continue }
        if let rect = child.lastAppliedLayoutPhysicalRect, rect.contains(location) {
            return child
        }
        guard let rect = try await child.getAxRect(.cancellable) else { continue }
        if rect.contains(location) { return child }
    }

    // Tiling: physical layout rects, then virtual, then AX fallback when rects are missing
    // (e.g. before the first successful layout pass finishes — common right after startup).
    if let w = location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: false,
        fullscreenCoversAll: true,
    ) {
        return w
    }
    if let w = location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: true,
        fullscreenCoversAll: true,
    ) {
        return w
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
    // AX uses the same top-left main-display space as AeroSpace layout rects / mouseLocation.
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }

    // Our HUD overlays sit above real windows in the AX z-order. If AX lands on our process,
    // don't report false (that aborted all focus-follows-mouse after the bar shipped).
    var pid: pid_t = 0
    if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
        return nil
    }

    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}
