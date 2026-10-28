import AppKit
import Common

enum EffectiveLeaf {
    case window(Window)
    case emptyWorkspace(Workspace)
}
extension LiveFocus {
    var asLeaf: EffectiveLeaf {
        if let windowOrNil { .window(windowOrNil) } else { .emptyWorkspace(workspace) }
    }
}

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. We keep it here only for 'on-focused-monitor-changed' to work
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        // A hidden app's window (cmd-H) is not a focus: it can't take keys, commands acting on it
        // act on nothing visible, and asking macOS to focus it unhides the app. The workspace's own
        // focus takes over. (Background native tabs share the parking container but are shown,
        // through their group's tile — those stay focusable.)
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
            .flatMap { $0.parent is MacosHiddenAppsWindowsContainer && $0.app.isHidden ? nil : $0 }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        let windowFocus = window?.toLiveFocusOrNil() ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitor
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus.
/// Commands must be cautious about accessing this property directly. There are legitimate cases.
/// But, in general, commands must firstly check --window-id, --workspace, AEROSPACE_WINDOW_ID env and
/// AEROSPACE_WORKSPACE env before accessing the global focus.
@MainActor var focus: LiveFocus { _focus.live }

/// i3 container focus: how many levels above the focused window the focus sits (`focus parent`).
/// 0 = the window itself. Any change of the focused window resets it (i3 focuses the leaf).
@MainActor private(set) var focusLevel: Int = 0

@MainActor func setFocusLevel(_ level: Int) {
    focusLevel = max(0, level)
}

extension LiveFocus {
    /// The node commands act on: the focused window, or with `focus parent` the tiling container
    /// that many levels above it (never above the workspace's root container, never for floats)
    @MainActor var focusedNode: TreeNode? {
        guard let window = windowOrNil else { return nil }
        var node: TreeNode = window
        var level = 0
        while level < focusLevel, let parent = node.parent as? TilingContainer {
            node = parent
            level += 1
        }
        return node
    }

    /// The deepest level `focus parent` can reach from the focused window
    @MainActor var maxFocusLevel: Int {
        guard let window = windowOrNil else { return 0 }
        var level = 0
        var node: TreeNode = window
        while let parent = node.parent as? TilingContainer {
            node = parent
            level += 1
        }
        return level
    }
}

/// Whether `windowId` is the focused window, by id (resolves even once the window has left the registry)
@MainActor func isFocusedWindowId(_ windowId: UInt32) -> Bool { _focus.windowId == windowId }

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    Kernel.noteModelMutation("setFocus")
    FrameTrace.log("model-focus \(_focus.windowId.map(String.init) ?? "nil")@\(_focus.workspaceName) -> \(newFocus.windowOrNil?.windowId.description ?? "nil")@\(newFocus.workspace.name) event=\(refreshSessionEvent.map { "\($0)" } ?? "none")")
    if newFocus.windowOrNil?.windowId != _focus.windowId { focusLevel = 0 }
    let oldFocus = focus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
    }

    _focus = newFocus.frozen
    let status = newFocus.workspace.workspaceMonitor.setActiveWorkspace(newFocus.workspace)

    if let window = newFocus.windowOrNil {
        window.hasEverBeenFocused = true
        // i3 con_activate_unblock: explicitly focusing another tiled window of the workspace
        // ends its fullscreen (floats — dialogs, pickers — are shown above it instead)
        if window.parent is TilingContainer, let ws = window.nodeWorkspace {
            for other in ws.rootTilingContainer.allLeafWindowsRecursive where other !== window && other.isFullscreen {
                other.exitFullscreen()
            }
        }
    }

    newFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() -> Bool {
        if let focus = toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            // todo We should also exit-native-hidden/unminimize[/exit-native-fullscreen?] window if we want to fix ID-B6E178F2
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() -> LiveFocus? { visualWorkspace.map { LiveFocus(windowOrNil: self, workspace: $0) } }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        // Never a window macOS owns (native fullscreen, a hidden app's): focusing it would take
        // the user off this workspace — onto the fullscreen Space, or unhiding the app. With only
        // such windows the workspace is shown empty, as i3 shows a workspace with nothing tiled.
        if let wd = mostRecentWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

// Used by workspace-back-and-forth
@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

// Used by focus-back-and-forth
@MainActor private var _prevFocus: FrozenFocus? = nil
/// The window of the previous focus, even when it no longer exists
@MainActor var prevFocusedWindowId: UInt32? { _prevFocus?.windowId }
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }

@MainActor private var onFocusChangedRecursionGuard = false
// Should be called in refreshSession
@MainActor func checkOnFocusChangedCallbacks_nonCancellable() async {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let focus = focus
    let frozenFocus = focus.frozen
    var hasFocusChanged = false
    var hasFocusedWorkspaceChanged = false
    var hasFocusedMonitorChanged = false
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
        hasFocusChanged = true
    }
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        _prevFocusedWorkspaceName = _lastKnownFocus.workspaceName
        hasFocusedWorkspaceChanged = true
    }
    if frozenFocus.monitorId_oneBased != _lastKnownFocus.monitorId_oneBased {
        hasFocusedMonitorChanged = true
    }
    _lastKnownFocus = frozenFocus

    if onFocusChangedRecursionGuard { return }
    onFocusChangedRecursionGuard = true
    defer { onFocusChangedRecursionGuard = false }
    // Workspace transition *before* window focus (i3 IPC + bars): emit workspace events first
    // so clients don't briefly paint the old workspace with the new window.
    if let _prevFocusedWorkspaceName, hasFocusedWorkspaceChanged {
        onWorkspaceChanged(_prevFocusedWorkspaceName, frozenFocus.workspaceName, focus)
    }
    if hasFocusChanged {
        raiseAlwaysOnTopWindows()
        applyMouseWarping(focus, focusedMonitorChanged: hasFocusedMonitorChanged)
        _ = await onFocusChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
    if hasFocusedMonitorChanged {
        _ = await onFocusedMonitorChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
}

@MainActor func onFocusedMonitorChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
    broadcastEvent(.focusedMonitorChanged(
        workspace: focus.workspace.name,
        monitorId_oneBased: focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
    ))
    return await config.onFocusedMonitorChanged.run(env.withFocus(focus), io)
}

@MainActor func onFocusChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
    broadcastEvent(.focusChanged(
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
    ))
    // Window event only after any workspace event from this transition (see call order above).
    i3IpcBroadcastWindowEvent(
        change: "focus",
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
    )
    return await config.onFocusChanged.run(env.withFocus(focus), io)
}

@MainActor private func onWorkspaceChanged(_ oldWorkspace: String, _ newWorkspace: String, _ focus: LiveFocus) {
    broadcastEvent(.workspaceChanged(
        workspace: newWorkspace,
        prevWorkspace: oldWorkspace,
    ))
    i3IpcBroadcastWorkspaceEvent(change: "focus", currentName: newWorkspace, oldName: oldWorkspace)
    if let exec = config.execOnWorkspaceChange.first, Headless.permits(.spawnProcess) {
        let process = Process()
        process.executableURL = URL(filePath: exec)
        process.arguments = Array(config.execOnWorkspaceChange.dropFirst())
        var environment = config.execConfig.envVariables
        environment[AEROSPACE_FOCUSED_WORKSPACE] = newWorkspace
        environment[AEROSPACE_PREV_WORKSPACE] = oldWorkspace
        environment["I3SOCK"] = i3IpcSocketPath
        switch focus.asLeaf {
            case .emptyWorkspace(let w):
                environment[AEROSPACE_WORKSPACE] = w.name
                environment[AEROSPACE_WINDOW_ID] = nil
            case .window(let w):
                environment[AEROSPACE_WORKSPACE] = nil
                environment[AEROSPACE_WINDOW_ID] = w.windowId.description
        }
        process.environment = environment
        _ = Result { try process.run() }
    }
}

/// `rename-workspace`: carry every name-keyed focus record over, so a rename is not seen as a
/// workspace switch (no focus / workspace-changed events, and back-and-forth still works)
@MainActor func noteWorkspaceRenamed(from old: String, to new: String) {
    func renamed(_ f: FrozenFocus) -> FrozenFocus {
        f.workspaceName == old ? FrozenFocus(windowId: f.windowId, workspaceName: new, monitorId_oneBased: f.monitorId_oneBased) : f
    }
    _focus = renamed(_focus)
    _lastKnownFocus = renamed(_lastKnownFocus)
    _prevFocus = _prevFocus.map(renamed)
    if _prevFocusedWorkspaceName == old { _prevFocusedWorkspaceName = new }
}
