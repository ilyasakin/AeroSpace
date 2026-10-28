import AppKit
import Common

struct FocusCommand: Command {
    let args: FocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        if let window = target.windowOrNil, await shouldFailBecauseFullscreen_nonCancellable(
            window: window,
            failIfFullscreen: args.failIfFullscreen,
            failIfMacosNativeFullscreen: args.failIfMacosNativeFullscreen,
        ) {
            return .fail
        }
        // AeroSpace's "floats take part in directional focus" pre-pass. Not for i3 semantics: in i3
        // floats are never in the tiling tree (they are cycled separately), and focus
        // floating|tiling|mode-toggle, parent/child, next/prev must see the real layers.
        let i3Semantics: Bool = switch args.target {
            case .direction: args.usesI3Semantics
            case .layer, .hierarchy, .sequence: true
            case .windowId, .dfsIndex, .dfsRelative: false
        }
        let floatsAsTiling = args.floatingAsTiling && !i3Semantics
        // todo bug: floating windows break mru
        let floatingWindows = floatsAsTiling ? await makeFloatingWindowsSeenAsTiling(workspace: target.workspace) : []
        defer {
            if floatsAsTiling {
                restoreFloatingWindows(floatingWindows: floatingWindows, workspace: target.workspace)
            }
        }

        switch args.target {
            case .sequence(let seq):
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                let node: TreeNode = window == focus.windowOrNil ? (focus.focusedNode ?? window) : window
                guard let parent = node.parent as? TilingContainer else { return .succ }
                switch seq {
                    case .next, .prev:
                        // i3 cmd_focus_direction next|prev: tree_next along the parent's orientation
                        let dir: CardinalDirection = switch (parent.orientation, seq == .next) {
                            case (.h, true): .right
                            case (.h, false): .left
                            case (.v, true): .down
                            case (.v, false): .up
                        }
                        return i3FocusDirection(target, dir, io)
                    case .nextSibling, .prevSibling:
                        // i3 get_tree_next_sibling: no wrap; a container sibling becomes the focused node
                        guard let index = node.ownIndex else { return .fail(io.err(bugPrompt())) }
                        let siblingIndex = index + (seq == .nextSibling ? 1 : -1)
                        guard parent.children.indices.contains(siblingIndex) else { return .succ }
                        let sibling = parent.children[siblingIndex]
                        guard let leaf = sibling.mostRecentWindowRecursive, leaf.focusWindow() else { return .fail }
                        var depth = 0
                        var n: TreeNode = leaf
                        while n !== sibling, let p = n.parent {
                            n = p
                            depth += 1
                        }
                        setFocusLevel(depth)
                        return .succ
                }
            case .layer(let layer):
                // i3: the most recently focused window of the other layer on this workspace
                let ws = target.workspace
                let wantFloating: Bool = switch layer {
                    case .floating: true
                    case .tiling: false
                    case .modeToggle: !(target.windowOrNil?.isFloating ?? false)
                }
                let pick = wantFloating
                    ? ws.floatingWindowsContainer.mostRecentWindowRecursive
                    : ws.rootTilingContainer.mostRecentWindowRecursive
                guard let pick else { return .succ }
                return .from(bool: pick.focusWindow())
            case .hierarchy(let h):
                // i3 `focus parent` stops at the workspace's root container; `focus child` at the
                // window. Neither changes which window has keyboard focus.
                guard target.windowOrNil != nil else { return .fail(io.err(noWindowIsFocused)) }
                switch h {
                    case .parent:
                        // i3: "Currently in fullscreen, not going up"
                        if focusLevel == 0, target.windowOrNil?.isFullscreen == true { return .succ }
                        if focusLevel >= focus.maxFocusLevel { return .succ }
                        setFocusLevel(focusLevel + 1)
                    case .child:
                        if focusLevel == 0 { return .succ }
                        setFocusLevel(focusLevel - 1)
                }
                return .succ
            case .direction(let direction) where args.usesI3Semantics:
                return i3FocusDirection(target, direction, io)
            case .direction(let direction):
                let window = target.windowOrNil
                if let (parent, ownIndex) = window?.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    guard let windowToFocus = parent.children[ownIndex + direction.focusOffset]
                        .findLeafWindowRecursive(snappedTo: direction.opposite) else { return .fail(io.err(bugPrompt())) }
                    return .from(bool: windowToFocus.focusWindow())
                } else {
                    return hitWorkspaceBoundaries(target, io, args, direction)
                }
            case .windowId(let windowId):
                if let windowToFocus = Window.get(byId: windowId) {
                    return .from(bool: windowToFocus.focusWindow())
                } else {
                    return .fail(io.err("Can't find window with ID \(windowId)"))
                }
            case .dfsIndex(let dfsIndex):
                if let windowToFocus = target.workspace.rootTilingContainer.allLeafWindowsRecursive.getOrNil(atIndex: Int(dfsIndex)) {
                    return .from(bool: windowToFocus.focusWindow())
                } else {
                    return .fail(io.err("Can't find window with DFS index \(dfsIndex)"))
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return .fail
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    switch args.boundariesAction {
                        case .stop: return .succ
                        case .fail: return .fail
                        case .wrapAroundTheWorkspace: targetIndex = (targetIndex + windows.count) % windows.count
                        case .wrapAroundAllMonitors: return .fail(io.err(bugPrompt("Must be discarded by args parser")))
                    }
                }
                return .from(bool: windows[targetIndex].focusWindow())
        }
    }
}

extension FocusCmdArgs {
    /// No explicit boundary flags: i3 `focus <direction>` with the `focus-wrapping` config
    var usesI3Semantics: Bool { rawBoundaries == nil && rawBoundariesAction == nil && !wrapAroundRequested }
}

/// i3 `tree_next` / `get_tree_next` (src/tree.c). Climb from the focused window to the first
/// ancestor running in the direction's orientation that has a sibling there; focus that sibling's
/// focused descendant (`con_descend_focused` — the focus stack, not geometry). With no sibling at
/// any level, `focus-wrapping` decides: the adjacent monitor, or a wrap to the far end of the
/// innermost matching ancestor. A fullscreen window only lets focus leave to another monitor.
@MainActor private func i3FocusDirection(_ target: LiveFocus, _ direction: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
    let wrapping = config.focusWrapping
    let o = direction.orientation
    // i3 get_tree_next on a floating con: left/right cycle the workspace's floats (wrapping),
    // up/down do nothing
    if let window = target.windowOrNil, window.isFloating, let floats = window.parent?.children {
        guard o == .h, floats.count > 1, let index = window.ownIndex else { return .succ }
        let next = floats[(index + direction.focusOffset + floats.count) % floats.count]
        return focusDescendant(of: next, io)
    }
    var firstWrap: TreeNode? = nil
    if let window = target.windowOrNil, !window.isFullscreen, window.parent is TilingContainer {
        // From a focused container (`focus parent`), climb from the container (i3 get_tree_next)
        var con: TreeNode = window == focus.windowOrNil ? (focus.focusedNode ?? window) : window
        while let parent = con.parent as? TilingContainer {
            if parent.children.count > 1 && parent.orientation == o, let index = con.ownIndex {
                let nextIndex = index + direction.focusOffset
                if parent.children.indices.contains(nextIndex) {
                    return focusDescendant(of: parent.children[nextIndex], io)
                }
                let wrap = direction.isPositive ? parent.children.first : parent.children.last
                switch wrapping {
                    case .no: break
                    case .yes, .workspace: firstWrap = firstWrap ?? wrap
                    case .force: return wrap.map { focusDescendant(of: $0, io) } ?? .succ
                }
            }
            con = parent
        }
    }
    if wrapping == .workspace {
        return firstWrap.map { focusDescendant(of: $0, io) } ?? .succ
    }
    if let (monitors, index) = target.workspace.workspaceMonitor.findRelativeMonitor(inDirection: direction),
       let targetMonitor = monitors.getOrNil(atIndex: index)
    {
        return .from(bool: targetMonitor.activeWorkspace.focusWorkspace())
    }
    return firstWrap.map { focusDescendant(of: $0, io) } ?? .succ
}

@MainActor private func focusDescendant(of node: TreeNode, _ io: CmdIo) -> BinaryExitCode {
    guard let window = node.mostRecentWindowRecursive else { return .fail(io.err(bugPrompt())) }
    return .from(bool: window.focusWindow())
}

@MainActor private func hitWorkspaceBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalDirection,
) -> BinaryExitCode {
    switch args.boundaries {
        case .workspace:
            return switch args.boundariesAction {
                case .stop: .succ
                case .fail: .fail
                case .wrapAroundTheWorkspace: wrapAroundTheWorkspace(target, io, direction)
                case .wrapAroundAllMonitors: .fail(io.err("Must be discarded by args parser"))
            }
        case .allMonitorsOuterFrame:
            let currentMonitor = target.workspace.workspaceMonitor
            guard let (monitors, index) = currentMonitor.findRelativeMonitor(inDirection: direction) else {
                return .fail(io.err(bugPrompt("Should never happen. Can't find the current monitor")))
            }

            if let targetMonitor = monitors.getOrNil(atIndex: index) {
                return .from(bool: targetMonitor.activeWorkspace.focusWorkspace())
            } else {
                guard let wrapped = monitors.get(wrappingIndex: index) else { return .fail(io.err(bugPrompt("\(index) \(monitors)"))) }
                return hitAllMonitorsOuterFrameBoundaries(target, io, args, direction, wrapped)
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalDirection,
    _ wrappedMonitor: Monitor,
) -> BinaryExitCode {
    switch args.boundariesAction {
        case .stop:
            return .succ
        case .fail:
            return .fail
        case .wrapAroundTheWorkspace:
            return wrapAroundTheWorkspace(target, io, direction)
        case .wrapAroundAllMonitors:
            wrappedMonitor.activeWorkspace.findLeafWindowRecursive(snappedTo: direction.opposite)?.markAsMostRecentChild()
            return .from(bool: wrappedMonitor.activeWorkspace.focusWorkspace())
    }
}

@MainActor private func wrapAroundTheWorkspace(_ target: LiveFocus, _ io: CmdIo, _ direction: CardinalDirection) -> BinaryExitCode {
    guard let windowToFocus = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite) else {
        return .fail(io.err(noWindowIsFocused))
    }
    return .from(bool: windowToFocus.focusWindow())
}

@MainActor private func makeFloatingWindowsSeenAsTiling(workspace: Workspace) async -> [FloatingWindowData] {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer {
        mruBefore?.markAsMostRecentChild()
    }
    var _floatingWindows: [FloatingWindowData] = []
    for window in workspace.floatingWindows {
        // todo bug: we shouldn't access ax api here. What if the window was moved but it wasn't committed to ax yet?
        guard let center = try? await window.getCenter(.nonCancellable) else { continue }

        let tilingParent: TilingContainer
        let index: Int
        if let target = center.coerce(in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)?
            .findWindowRecursively(in: workspace.rootTilingContainer, virtual: true, fullscreenCoversAll: false)
        {
            guard let targetCenter = try? await target.getCenter(.nonCancellable) else { continue }
            guard let _tilingParent = target.parent as? TilingContainer else { continue }
            tilingParent = _tilingParent
            index = switch tilingParent.layout {
                case .tiles, .master:
                    center.getProjection(tilingParent.orientation) >= targetCenter.getProjection(tilingParent.orientation)
                        ? target.ownIndex.orDie() + 1
                        : target.ownIndex.orDie()
                case .accordion:
                    center.getProjection(tilingParent.orientation) >= targetCenter.getProjection(tilingParent.orientation)
                        ? tilingParent.children.count
                        : 0
            }
        } else {
            index = 0
            tilingParent = workspace.rootTilingContainer
        }

        let data = window.unbindFromParent()
        let floatingWindowData = FloatingWindowData(
            window: window,
            center: center,
            tilingParent: tilingParent,
            adaptiveWeight: data.adaptiveWeight,
            index: index,
        )
        _floatingWindows.append(floatingWindowData)
    }
    let floatingWindows: [FloatingWindowData] = _floatingWindows.sortedBy { $0.center.getProjection($0.tilingParent.orientation) }.reversed()

    for floating in floatingWindows { // Make floating windows be seen as tiling
        floating.window.bind(to: floating.tilingParent, adaptiveWeight: 1, index: floating.index)
    }
    return floatingWindows
}

@MainActor private func restoreFloatingWindows(floatingWindows: [FloatingWindowData], workspace: Workspace) {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer {
        mruBefore?.markAsMostRecentChild()
    }
    for floating in floatingWindows {
        floating.window.bind(to: workspace.floatingWindowsContainer, adaptiveWeight: floating.adaptiveWeight, index: INDEX_BIND_LAST)
    }
}

private struct FloatingWindowData {
    let window: Window
    let center: CGPoint

    let tilingParent: TilingContainer
    let adaptiveWeight: CGFloat
    let index: Int
}

extension TreeNode {
    @MainActor
    func findLeafWindowRecursive(snappedTo direction: CardinalDirection) -> Window? {
        switch nodeCases {
            case .workspace(let workspace):
                return workspace.rootTilingContainer.findLeafWindowRecursive(snappedTo: direction)
            case .window(let window):
                return window
            case .tilingContainer(let container):
                if direction.orientation == container.orientation {
                    return (direction.isPositive ? container.children.last : container.children.first)?
                        .findLeafWindowRecursive(snappedTo: direction)
                } else {
                    return mostRecentChild?.findLeafWindowRecursive(snappedTo: direction)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer,
                 .floatingWindowsContainer:
                die("Impossible")
        }
    }
}
