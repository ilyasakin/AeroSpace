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

            // 1) Cheap geometry only — no AX. Most moves stay inside the same tile.
            guard let window = windowUnderMouseCheap(location) else {
                // 2) Optional AX fallback when layout rects miss (rare after layout is warm).
                try checkCancellation()
                if await isAxWindowUnderMouse(location) == false { return }
                guard let window = try await windowUnderMouseAxFallback(location) else { return }
                try await focusFollowsApply(window, token: token)
                return
            }

            // Already focused — zero session work (this is the hot path while moving inside a window).
            if window.windowId == focusFollowsLastFocusedId
                || window.windowId == focus.windowOrNil?.windowId
            {
                focusFollowsLastFocusedId = window.windowId
                return
            }

            // 3) Menu / desktop filter only when we are about to change focus (not every pixel).
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
        _ = window.focusWindow()
        window.nativeFocus()
    }
    focusFollowsLastFocusedId = window.windowId
}

/// Geometry-only hit test using layout rects (no AX). Fast enough for every mouse-move settle.
@MainActor
private func windowUnderMouseCheap(_ location: CGPoint) -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace

    for child in workspace.floatingWindowsContainer.mruChildren {
        guard let child = child as? Window else { continue }
        if let rect = child.lastAppliedLayoutPhysicalRect ?? child.lastAppliedLayoutVirtualRect,
           rect.contains(location)
        {
            return child
        }
    }

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

/// AX rect scan — only when cheap geometry found nothing.
@MainActor
private func windowUnderMouseAxFallback(_ location: CGPoint) async throws -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace
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
