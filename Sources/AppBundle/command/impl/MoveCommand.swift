import AppKit
import Common

struct MoveCommand: Command {
    let args: MoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        if await shouldFailBecauseFullscreen_nonCancellable(
            window: currentWindow,
            failIfFullscreen: args.failIfFullscreen,
            failIfMacosNativeFullscreen: args.failIfMacosNativeFullscreen,
        ) {
            return .fail
        }
        switch currentWindow.windowParentCases {
            case .unbound: return .fail
            case .tilingContainer:
                // With `focus parent`, the focused CONTAINER moves (i3 moves the focused con)
                let node: TreeNode = currentWindow == focus.windowOrNil ? (focus.focusedNode ?? currentWindow) : currentWindow
                return i3TreeMove(node, direction, io, args, env)
            case .floatingWindowsContainer:
                // i3: a floating window moves by <px> (default 10) in the direction
                let amount = CGFloat(args.floatingAmount ?? 10)
                guard let rect = try? await currentWindow.intendedFrame(.nonCancellable) else {
                    return .fail(io.err("The window's frame is unknown"))
                }
                let delta: CGPoint = switch direction {
                    case .left: CGPoint(x: -amount, y: 0)
                    case .right: CGPoint(x: amount, y: 0)
                    case .up: CGPoint(x: 0, y: -amount)
                    case .down: CGPoint(x: 0, y: amount)
                }
                currentWindow.requestFrame(topLeft: rect.topLeftCorner + delta, size: nil)
                return .succ
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err(moveOutMacosUnconventionalWindow))
            case .macosPopupWindowsContainer:
                return .fail(io.err(bugPrompt())) // Impossible
        }
    }
}

/// i3 `tree_move` (src/move.c), 1:1 on the tiling tree. The root tiling container plays the i3
/// workspace con (it carries the workspace's layout/orientation).
///
/// 1. Find the nearest ancestor split in the move's orientation; if there is none, force the
///    workspace into that orientation (i3 `ws_force_orientation`: wrap the root's children).
/// 2. Inside that parent: a leaf neighbour → swap; a container neighbour → descend into it along
///    the move direction (`con_descend_direction`) and insert at its near end. No neighbour and
///    the parent is the root → the window is at the workspace edge (next output).
/// 3. Otherwise climb: `above` is the ancestor directly inside the split; the window enters the
///    bordering branch of `above`'s neighbour if that is a container, else lands next to `above`.
@MainActor private func i3TreeMove(
    _ window: TreeNode,
    _ direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    guard let workspace = window.nodeWorkspace else { return .fail }
    // i3: "Not moving workspace" — the focused node is the whole root container
    if window === workspace.rootTilingContainer { return .succ }
    let o = direction.orientation
    let towardsStart = !direction.isPositive

    // "This is the only con on this workspace" / a fullscreen window moves to the next output
    if (window as? Window)?.isFullscreen == true ||
        window.parent === workspace.rootTilingContainer && workspace.rootTilingContainer.children.count == 1
    {
        return hitWorkspaceBoundaries(window, workspace, io, args, direction, env)
    }

    var sameOrientation = window.i3ParentWithOrientation(o)
    repeat {
        if sameOrientation == nil {
            // With explicit --boundaries / --boundaries-action, a missing ancestor in this
            // orientation IS the workspace boundary (legacy AeroSpace semantics)
            if args.rawBoundaries != nil || args.rawBoundariesAction != nil {
                return hitWorkspaceBoundaries(window, workspace, io, args, direction, env)
            }
            workspace.forceRootOrientation(o)
            sameOrientation = window.i3ParentWithOrientation(o)
        }
        guard let parent = window.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
        if sameOrientation === parent {
            guard let index = window.ownIndex else { return .fail(io.err(bugPrompt())) }
            let swapIndex = index + direction.focusOffset
            if parent.children.indices.contains(swapIndex) {
                let swap = parent.children[swapIndex]
                if let swapContainer = swap as? TilingContainer {
                    insertI3(window, intoBorderingBranchOf: swapContainer, direction)
                    return .succ
                }
                // Swap with sibling; the weight travels with the node
                if !((window as? Window).map { workspace.commitTilingMoveWindow($0.windowId, toIndexInParent: swapIndex) } ?? false) {
                    let prevBinding = window.unbindFromParent()
                    window.bind(to: parent, adaptiveWeight: prevBinding.adaptiveWeight, index: swapIndex)
                }
                return .succ
            }
            if parent === workspace.rootTilingContainer {
                return hitWorkspaceBoundaries(window, workspace, io, args, direction, env)
            }
            // No sibling to swap with: search again one level higher
            sameOrientation = parent.i3ParentWithOrientation(o)
        }
    } while sameOrientation == nil
    guard let sameOrientation else { return .fail(io.err(bugPrompt())) }

    // `above`: the ancestor of window directly inside sameOrientation
    var above: TreeNode = window
    while let p = above.parent, p !== sameOrientation { above = p }
    guard let aboveIndex = above.ownIndex else { return .fail(io.err(bugPrompt())) }
    let nextIndex = aboveIndex + direction.focusOffset
    let next = sameOrientation.children.indices.contains(nextIndex) ? sameOrientation.children[nextIndex] : nil

    if let nextContainer = next as? TilingContainer {
        insertI3(window, intoBorderingBranchOf: nextContainer, direction)
    } else if next == nil,
              let parent = window.parent as? TilingContainer,
              parent.parent === workspace.rootTilingContainer,
              parent.layout != .tiles,
              parent.children.count == 1
    {
        // Lone child of a non-default-layout container at the workspace edge: treat the
        // workspace as its parent
        return hitWorkspaceBoundaries(window, workspace, io, args, direction, env)
    } else {
        // Into the container above, beside `above`
        window.bind(to: sameOrientation, adaptiveWeight: WEIGHT_AUTO, index: aboveIndex + (towardsStart ? 0 : 1))
    }
    return .succ
}

/// i3 `con_descend_direction` + `insert_con_into`: enter `branch` from the side we are moving
/// towards and insert next to the leaf found there — at the near end when that leaf's parent runs
/// in the move orientation, after it otherwise.
@MainActor private func insertI3(_ window: TreeNode, intoBorderingBranchOf branch: TilingContainer, _ direction: CardinalDirection) {
    let target = branch.i3DescendDirection(direction)
    guard let targetParent = target.parent as? TilingContainer, let targetIndex = target.ownIndex else { return }
    let after = targetParent.orientation != direction.orientation || !direction.isPositive
    // Unbinding the window may shift the target's index when both share a parent
    let sameParentBefore = window.parent === targetParent && (window.ownIndex ?? Int.max) < targetIndex
    let index = targetIndex + (after ? 1 : 0) - (sameParentBefore ? 1 : 0)
    window.bind(to: targetParent, adaptiveWeight: WEIGHT_AUTO, index: index)
}

extension TreeNode {
    /// i3 `con_parent_with_orientation`: nearest ANCESTOR tiling container with orientation `o`
    /// (nil when the tiling tree has none; floating windows never have one)
    @MainActor func i3ParentWithOrientation(_ o: Orientation) -> TilingContainer? {
        var p = parent as? TilingContainer
        while let c = p, c.orientation != o { p = c.parent as? TilingContainer }
        return p
    }

    /// i3 `con_descend_direction`: the leaf where a move in `direction` enters this subtree —
    /// first/last child along a matching orientation, the focused child across it.
    @MainActor func i3DescendDirection(_ direction: CardinalDirection) -> TreeNode {
        guard let container = self as? TilingContainer, !container.children.isEmpty else { return self }
        let most: TreeNode? = container.orientation == direction.orientation
            ? (direction.isPositive ? container.children.first : container.children.last)
            : container.mostRecentChild
        return most?.i3DescendDirection(direction) ?? self
    }
}

extension Workspace {
    /// i3 `ws_force_orientation`: move every root child into a new container carrying the root's
    /// current layout, and switch the root to `o`.
    @MainActor func forceRootOrientation(_ o: Orientation) {
        let prevRoot = rootTilingContainer
        let focusOrder = prevRoot.windowsInFocusOrder
        prevRoot.unbindFromParent()
        _ = TilingContainer(parent: self, adaptiveWeight: WEIGHT_AUTO, o, .tiles, index: 0)
        prevRoot.bind(to: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        for w in focusOrder.reversed() { w.markAsMostRecentChild() }
    }
}

@MainActor private func hitWorkspaceBoundaries(
    _ node: TreeNode,
    _ workspace: Workspace,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
    _ env: CmdEnv,
) -> BinaryExitCode {
    // Crossing to another monitor is window-only (move-node-to-monitor moves one window)
    func moveToAdjacentMonitor() -> BinaryExitCode? {
        guard let window = node as? Window,
              let (monitors, index) = window.nodeMonitor?.findRelativeMonitor(inDirection: direction),
              monitors.indices.contains(index)
        else { return nil }
        let moveNodeToMonitorArgs = MoveNodeToMonitorCmdArgs(target: .direction(direction))
            .copy(\.windowId, window.windowId)
            .copy(\.focusFollowsWindow, focus.windowOrNil == window)
        return MoveNodeToMonitorCommand(args: moveNodeToMonitorArgs).run(env, io)
    }
    // i3 default (no explicit flags): at the workspace edge the window moves to the adjacent output,
    // or stays put if there is none (move.c move_to_output_directed)
    if args.rawBoundaries == nil && args.rawBoundariesAction == nil {
        return moveToAdjacentMonitor() ?? .succ
    }
    switch args.boundaries {
        case .workspace:
            return applyBoundariesAction(node, workspace, args, direction)
        case .allMonitorsOuterFrame:
            return moveToAdjacentMonitor() ?? applyBoundariesAction(node, workspace, args, direction)
    }
}

@MainActor private func applyBoundariesAction(
    _ node: TreeNode,
    _ workspace: Workspace,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
) -> BinaryExitCode {
    switch args.boundariesAction {
        case .stop: return .succ
        case .fail: return .fail
        case .createImplicitContainer:
            createImplicitContainerAndMoveWindow(node, workspace, direction)
            return .succ
    }
}

private let moveOutMacosUnconventionalWindow = "moving macOS fullscreen, minimized windows and windows of hidden apps isn't yet supported. This behavior is subject to change"

@MainActor private func createImplicitContainerAndMoveWindow(
    _ window: TreeNode,
    _ workspace: Workspace,
    _ direction: CardinalDirection,
) {
    let prevRoot = workspace.rootTilingContainer
    prevRoot.unbindFromParent()
    // Force tiles layout
    _ = TilingContainer(parent: workspace, adaptiveWeight: WEIGHT_AUTO, direction.orientation, .tiles, index: 0)
    check(prevRoot != workspace.rootTilingContainer)
    prevRoot.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset)
}

func shouldFailBecauseFullscreen_nonCancellable(
    window: Window,
    failIfFullscreen: Bool,
    failIfMacosNativeFullscreen: Bool,
) async -> Bool {
    if failIfFullscreen && window.isFullscreen {
        return true
    }
    if failIfMacosNativeFullscreen {
        if true == (try? await window.isMacosFullscreen(.nonCancellable)) {
            return true
        }
    }
    return false
}
