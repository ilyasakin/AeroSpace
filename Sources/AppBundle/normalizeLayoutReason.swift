@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.allUnsorted {
        // Empty workspaces have nothing to reparent; skip the leaf walk + per-window async
        if workspace.isEffectivelyEmpty { continue }
        try await _normalizeLayoutReason(workspace: workspace, windows: workspace.allLeafWindowsRecursive)
    }
    let minimized = macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    if !minimized.isEmpty {
        try await _normalizeLayoutReason(workspace: focus.workspace, windows: minimized)
    }
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    if macosPopupWindowsContainer.children.isEmpty { return }
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.resolveWindowType(windowLevel, .cancellable) != .popup {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        // Fast path: standard window already known-normal and app visible — nothing to do.
        // Avoids an async hop per window on every heavy refresh when the cache is warm
        // (the common case: focus/command churn with no native fullscreen/minimize transitions)
        if case .standard = window.layoutReason,
           let cached = peekMacosNativeWindowState(window.windowId),
           !cached.isFullscreen,
           !cached.isMinimized,
           config.automaticallyUnhideMacosHiddenApps || !window.macAppUnsafe.nsApp.isHidden
        {
            continue
        }

        let nativeState = try await getMacosNativeWindowState(window)
        let isMacosFullscreen = nativeState.isFullscreen
        let isMacosMinimized = nativeState.isMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
