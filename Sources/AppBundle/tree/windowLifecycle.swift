import AppKit
import Common

extension Window {
    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if Window.registry.removeValue(forKey: windowId) == nil {
            return
        }
        invalidateMacosNativeWindowStateCache(windowId: windowId)
        if !skipClosedWindowsCache { WindowMemory.freezeWorldIfNeeded() }
        // Remember the workspace: windows can vanish from AX transiently (VLC/native fullscreen
        // hides the windowed window; some apps drop windows from their AX list under load) and
        // re-register moments later — without this they landed on whatever workspace was focused
        // at re-registration ("VLC migrated ws1 → ws5 after a fullscreen round-trip").
        if let ws = nodeWorkspace {
            WindowMemory.noteLeaving(self, from: ws.name)
        }
        handOverTileToParkedTabSibling()
        if isFocusedWindowId(windowId) { FocusReconciler.noteFocusHandoff() }
        // Only the focus that was on this window moves. Any other window closing (a background
        // job's window) re-picked the workspace's focus — off a native-fullscreen window, pulling
        // the user out of its Space — or, within a second of a workspace switch, dragged the user
        // back to the workspace they had just left
        let wasFocused = focus.windowOrNil === self
        let wasJustFocused = prevFocusedWindowId == windowId && prevFocusedWorkspaceDate.distance(to: .now) < 1
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, wasFocused && deadWindowWorkspace == focus.workspace ||
            wasJustFocused && deadWindowWorkspace == prevFocusedWorkspace
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // The end of the session asks macOS for the new focus — to fix the macOS annoyance
                    // of a focused app without windows (#65). But when the focused app closed its own
                    // window, macOS focuses another of its windows itself; asking would fight it
                    // (the "Apple Reminders popup" bug, #201)
                    if focus.windowOrNil?.app.pid == app.pid, let next = deadWindowFocus.windowOrNil {
                        FocusReconciler.expect(next.windowId)
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }
}
