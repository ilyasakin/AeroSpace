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
        guard let popup = node as? Window else { continue }
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await MacOS.current.windowType(popup.windowId, level: windowLevel, .cancellable) != .popup {
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
        ? parkedNativeTabSiblings(windows, monitorRect: workspace.workspaceMonitor.rect)
        : []

    // Windows coming back from a macOS state are restored last-parked-first: each exact-spine
    // restore then sees the spine its own removal left behind (cmd-H parks every window of the
    // app in one pass; unhide must unwind them in reverse to rebuild the original tree).
    let windows = windows.enumerated().sorted { a, b in
        let sa = a.element.tileRestoreSequence, sb = b.element.tileRestoreSequence
        return sa != sb ? sa > sb : a.offset < b.offset
    }.map(\.element)

    for window in windows {
        let isParkedTab = parkedTabs.contains(window.windowId)

        // Fast path: standard window already known-normal, app visible, and not a parked tab —
        // nothing to do. Avoids an async hop per window on every heavy refresh when the cache is warm
        if case .standard = window.layoutReason,
           let cached = peekMacosNativeWindowState(window.windowId),
           !cached.isFullscreen,
           !cached.isMinimized,
           config.automaticallyUnhideMacosHiddenApps || !window.app.isHidden,
           !isParkedTab
        {
            continue
        }

        // Unreadable (busy app / dying window): unknown is not "normal" — keep the current reason
        guard let nativeState = try await getMacosNativeWindowState(window) else { continue }
        let isMacosFullscreen = nativeState.isFullscreen
        let isMacosMinimized = nativeState.isMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.app.isHidden
        FrameTrace.log("native-state \(window.windowId) fullscreen=\(isMacosFullscreen) minimized=\(isMacosMinimized) hiddenApp=\(isMacosWindowOfHiddenApp) reason=\(window.layoutReason)")
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                // Leaving tiling for a macOS-owned container: remember the tile so the window
                // returns to it (unminimize / exit fullscreen / unhide / tab handover)
                let parks = isMacosFullscreen || isMacosMinimized || isMacosWindowOfHiddenApp || isParkedTab
                if parks { workspace.captureTileRestorePoint(for: window) }
                defer { if parks { workspace.settleTileRestorePoint(for: window) } }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        if focus.windowOrNil === window { FocusReconciler.noteFocusHandoff() }
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        // The minimized container is GLOBAL — it erases workspace identity, so
                        // unminimize used to land on whatever workspace was focused. Remember.
                        if let ws = window.nodeWorkspace {
                            WindowMemory.noteLeaving(window, from: ws.name)
                        }
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        if focus.windowOrNil === window { FocusReconciler.noteFocusHandoff() }
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
                // Tab membership is only KNOWN for a visible workspace: hidden windows all sit at
                // the hide corner, so their frames say nothing. A sibling parked as a native tab
                // must therefore stay parked while its workspace is invisible. Un-parking it here
                // re-tiled it beside the MRU window every time the user switched away, and the
                // heavy after switching back parked it again — a structural round trip on the
                // workspace the user had just left. It is re-evaluated by the first heavy after
                // the workspace is shown, which runs before layout.
                let tabStateUnknown = detectNativeTabs && !workspace.isVisible
                if tabStateUnknown, window.parent is MacosHiddenAppsWindowsContainer,
                   !isMacosFullscreen, !isMacosMinimized, !isMacosWindowOfHiddenApp
                {
                    continue
                }
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
///
/// Two same-app windows sharing a frame are only evidence of a tab group when AeroSpace did not
/// put them there itself, and when macOS is actually showing them as ONE window. Two guards, both
/// pure (`NativeTabDetection`):
/// - Off-monitor frames are never evidence. `hideInCorner` parks every window of an invisible
///   workspace at the SAME point, so two equal-weight tiles of one app share a frame exactly while
///   hidden; WindowServer lags the AX write on switch-back, so the follow-up heavy could still read
///   both at the corner, "detect" a tab group and yank the higher id out of tiling (the next heavy
///   un-parked it beside the MRU window: shuffled tiles).
/// - macOS orders background tabs OUT, so a real tab group has at most one member on screen. Two
///   on-screen same-frame windows are separate windows that merely overlap (an app opening a new
///   window exactly on top of its last one) and must both tile.
/// An earlier guard skipped windows whose frame was written this session; heavies never clear
/// those marks, so a tab group whose members kept being rewritten was never detected at all.
@MainActor
private func parkedNativeTabSiblings(_ windows: [Window], monitorRect: Rect) -> Set<UInt32> {
    var countByPid: [Int32: Int] = [:]
    for w in windows { countByPid[w.app.pid, default: 0] += 1 }
    // Accordion members are laid out to (near-)identical frames on purpose — with
    // `accordion-padding = 0` they are pixel-identical — so same-app members of one accordion
    // would read as a tab group and the higher ids would be pulled out of the accordion.
    let candidates = windows.filter {
        (countByPid[$0.app.pid] ?? 0) > 1 && ($0.parent as? TilingContainer)?.layout != .accordion
    }
    guard !candidates.isEmpty else { return [] }
    let onScreen = WindowServerReads.current.onScreenSnapshot().levels
    let evidence = NativeTabDetection.tabEvidence(
        candidates.map { (pid: $0.app.pid, id: $0.windowId) },
        monitorRect: monitorRect,
        frameOf: { WindowServerReads.current.windowBounds(windowId: $0, forOverlay: true) },
        isOnScreen: { onScreen[$0] != nil },
    )
    return NativeTabDetection.parkedSiblingIds(evidence)
}

/// Pure decision, extracted so the deterministic representative/sibling logic is unit-testable.
enum NativeTabDetection {
    typealias Evidence = (pid: Int32, id: UInt32, frame: Rect, onScreen: Bool)

    /// Frames that may serve as tab-group evidence: a frame whose center lies off the workspace's
    /// monitor is a corner-parked window, never a visible tab group, and is dropped.
    static func tabEvidence(
        _ windows: [(pid: Int32, id: UInt32)],
        monitorRect: Rect,
        frameOf: (UInt32) -> Rect?,
        isOnScreen: (UInt32) -> Bool,
    ) -> [Evidence] {
        windows.compactMap { w in
            guard let frame = frameOf(w.id), monitorRect.contains(frame.center) else { return nil }
            return (w.pid, w.id, frame, isOnScreen(w.id))
        }
    }

    /// Within each set of same-app windows sharing the exact same frame (a native tab group), the
    /// lowest window id is the representative (kept tiled); every higher-id member is a parked
    /// sibling. Deterministic in id order, so a group never flaps or transiently double-tiles.
    /// A set with two or more members on screen is not a tab group (macOS orders background tabs
    /// out), just windows that overlap.
    static func parkedSiblingIds(_ windows: [Evidence]) -> Set<UInt32> {
        var parked = Set<UInt32>()
        for w in windows {
            let group = windows.filter { $0.pid == w.pid && rectsApproximatelyEqual($0.frame, w.frame) }
            if group.count(where: \.onScreen) >= 2 { continue }
            if group.contains(where: { $0.id < w.id }) { parked.insert(w.id) }
        }
        return parked
    }

    /// Frames only (no on-screen information): every same-frame set counts as a group
    static func parkedSiblingIds(_ windows: [(pid: Int32, id: UInt32, frame: Rect)]) -> Set<UInt32> {
        parkedSiblingIds(windows.map { ($0.pid, $0.id, $0.frame, false) })
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
    // Prefer the workspace the window lived on when it entered the unconventional state
    // (minimize erases it via the global container). Falls back to the caller's workspace.
    let workspace = WindowMemory.recallDeparture(windowId: window.windowId) ?? workspace
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            // Back to its own tile (i3 never reorders on these round trips); new-window placement
            // (beside the focused window, reset weight) only if nothing about the slot survived
            if !workspace.restoreTile(window) {
                try await window.relayoutWindow(on: workspace, cm, forceTile: true)
            }
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
