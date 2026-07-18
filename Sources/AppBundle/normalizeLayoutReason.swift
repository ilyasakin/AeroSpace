import Common
import Foundation

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.allUnsorted {
        // Empty workspaces have nothing to reparent; skip the leaf walk + per-window async
        if workspace.isEffectivelyEmpty { continue }
        try await _normalizeLayoutReason(workspace: workspace, windows: workspace.allLeafWindowsRecursive)
    }
    let minimized = macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    if !minimized.isEmpty {
        // Minimized windows are off-screen and share the parked corner — never native-tab candidates
        try await _normalizeLayoutReason(workspace: focus.workspace, windows: minimized, detectNativeTabs: false)
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
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], detectNativeTabs: Bool = true) async throws {
    // Native tab groups (Alacritty Cmd+T, Safari/Finder tabs, …) are same-app windows sharing one
    // frame. Only the group's representative (lowest window id) is tiled — its tile shows whichever
    // tab is active, since tabs share a frame — so the group occupies one stable tile and switching
    // tabs never reflows. Every other member is parked. Computed once per pass, visible workspace only.
    let parkedTabs: Set<UInt32> = detectNativeTabs && workspace.isVisible
        ? parkedNativeTabSiblings(windows)
        : []

    for window in windows {
        let isParkedTab = parkedTabs.contains(window.windowId)

        // Fast path: standard window already known-normal, app visible, and not a parked tab —
        // nothing to do. Avoids an async hop per window on every heavy refresh when the cache is warm
        if case .standard = window.layoutReason,
           let cached = peekMacosNativeWindowState(window.windowId),
           !cached.isFullscreen,
           !cached.isMinimized,
           config.automaticallyUnhideMacosHiddenApps || !window.macAppUnsafe.nsApp.isHidden,
           !isParkedTab
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
                    case isParkedTab:
                        // Non-representative native tab: same app + frame as a lower-id sibling that
                        // holds the group's tile. Park it out of tiling so the group keeps ONE stable
                        // tile — no empty pane, and switching/creating tabs never repositions it.
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                // The representative is never in parkedTabs, so it stays tiled even while it's a
                // background tab. A parked sibling re-tiles only when it becomes the representative
                // (its lower-id siblings closed).
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp && !isParkedTab {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

/// Ids of the non-representative native-tab siblings among `windows` (they get parked). Only apps
/// with more than one window here can have tabs, so the WindowServer frame read happens only for
/// those — the common single-window-per-app case stays IPC-free. Caller gates to visible workspaces.
@MainActor
private func parkedNativeTabSiblings(_ windows: [Window]) -> Set<UInt32> {
    var countByPid: [Int32: Int] = [:]
    for w in windows { countByPid[w.app.pid, default: 0] += 1 }
    let candidates = windows.filter { (countByPid[$0.app.pid] ?? 0) > 1 }
    guard !candidates.isEmpty else { return [] }
    let framed: [(pid: Int32, id: UInt32, frame: Rect)] = candidates.compactMap { w in
        SkyLight.overlayBounds(w.windowId).map { (w.app.pid, w.windowId, $0) }
    }
    return NativeTabDetection.parkedSiblingIds(framed)
}

/// Pure decision, extracted so the deterministic representative/sibling logic is unit-testable.
enum NativeTabDetection {
    /// Within each set of same-app windows sharing the exact same frame (a native tab group), the
    /// lowest window id is the representative (kept tiled); every higher-id member is a parked
    /// sibling. Deterministic in id order, so a group never flaps or transiently double-tiles.
    static func parkedSiblingIds(_ windows: [(pid: Int32, id: UInt32, frame: Rect)]) -> Set<UInt32> {
        var parked = Set<UInt32>()
        for w in windows {
            let hasLowerRepresentative = windows.contains { other in
                other.pid == w.pid && other.id < w.id && rectsApproximatelyEqual(other.frame, w.frame)
            }
            if hasLowerRepresentative { parked.insert(w.id) }
        }
        return parked
    }

    static func rectsApproximatelyEqual(_ a: Rect, _ b: Rect, tolerance: CGFloat = 2) -> Bool {
        abs(a.topLeftX - b.topLeftX) <= tolerance && abs(a.topLeftY - b.topLeftY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
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
