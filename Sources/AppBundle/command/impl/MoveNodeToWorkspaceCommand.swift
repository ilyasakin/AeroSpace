import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .relative(let nextPrev):
                guard let subjectWs else { return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace")) }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                )
                guard let ws = ws.getOrNil(appendErrorTo: &io.stderr) else { return .fail }
                targetWorkspace = ws
            case .direct(let name):
                if name.raw == scratchpadWorkspaceName { return .fail(io.err("Use 'scratchpad move' to move a window to the scratchpad")) }
                targetWorkspace = Workspace.get(byName: args.number ? workspaceNamed(number: name.raw) : name.raw)
            case .backAndForth:
                // i3 `move container to workspace back_and_forth`
                guard let prev = prevFocusedWorkspace else { return .fail(io.err("No previous workspace")) }
                targetWorkspace = prev
        }
        // `focus parent`: the whole focused container moves (i3 `move container to workspace`)
        if window == focus.windowOrNil, let container = focus.focusedNode as? TilingContainer,
           container !== container.nodeWorkspace?.rootTilingContainer
        {
            return moveContainerToWorkspace(container, targetWorkspace, io, focusFollows: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }
}

@MainActor
func moveContainerToWorkspace(_ container: TilingContainer, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollows: Bool, failIfNoop: Bool) -> BinaryExitCode {
    if container.nodeWorkspace == targetWorkspace {
        return failIfNoop ? .fail : .succ
    }
    let focusedWindow = focus.windowOrNil
    let level = focusLevel
    if targetWorkspace.allLeafWindowsRecursive.contains(where: \.isFullscreen) {
        for w in container.allLeafWindowsRecursive where w.isFullscreen { w.exitFullscreen() }
    }
    if let anchor = targetWorkspace.rootTilingContainer.mostRecentWindowRecursive,
       let anchorParent = anchor.parent as? TilingContainer,
       let anchorIndex = anchor.ownIndex
    {
        container.bind(to: anchorParent, adaptiveWeight: WEIGHT_AUTO, index: anchorIndex + 1)
    } else {
        container.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    if focusFollows, let focusedWindow {
        let ok = focusedWindow.focusWindow()
        setFocusLevel(level) // the moved container stays the focused node
        return .from(bool: ok)
    }
    return .succ
}

@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> BinaryExitCode {
    if window.nodeWorkspace == targetWorkspace {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    // Moving a sticky window to a specific workspace is an explicit statement that
    // the window should stop following the active workspace
    window.isSticky = false
    // i3 con_move_to_workspace: one fullscreen window per workspace — the arriving one yields
    if window.isFullscreen, targetWorkspace.allLeafWindowsRecursive.contains(where: \.isFullscreen) {
        window.exitFullscreen()
    }
    if window.isFloating {
        window.bind(to: targetWorkspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else if index == INDEX_BIND_LAST,
              let anchor = targetWorkspace.rootTilingContainer.mostRecentWindowRecursive,
              let anchorParent = anchor.parent as? TilingContainer,
              let anchorIndex = anchor.ownIndex
    {
        // i3 con_move_to_workspace: land right after the target workspace's focused tiling
        // window, as its sibling (was: appended to the root, which also broke dwindle's binary tree)
        window.bind(to: anchorParent, adaptiveWeight: WEIGHT_AUTO, index: anchorIndex + 1)
    } else {
        window.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    }
    return .from(bool: focusFollowsWindow ? window.focusWindow() : true)
}
