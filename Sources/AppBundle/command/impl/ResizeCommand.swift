import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        if let window = target.windowOrNil, window.isFloating {
            return await resizeFloatingWindow(window, io)
        }
        // `focus parent`: resize the focused container (i3 resizes the focused con)
        let subject: TreeNode? = target.windowOrNil == focus.windowOrNil ? focus.focusedNode : target.windowOrNil
        if let edge = args.dimension.val.edge {
            guard let subject else { return .fail(io.err(noWindowIsFocused)) }
            return resizeTowardNeighbour(subject, edge, io)
        }
        let candidates = subject?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .left, .down, .up, .right:
                return .fail(io.err(bugPrompt())) // handled above
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        // Weights are proportions; px amounts convert through the parent's rendered span
        let weightSum = CGFloat(parent.children.sumOfDouble { $0.getWeight(orientation) })
        let weightPerPx = parent.weightPerPixel(orientation)
        let current = node.getWeight(orientation)
        let diff: CGFloat = switch args.units.val {
            case .set(let px): CGFloat(px) * weightPerPx - current
            case .add(let px): CGFloat(px) * weightPerPx
            case .subtract(let px): -CGFloat(px) * weightPerPx
            // i3 `ppt`: percentage points of the parent's span
            case .setPercent(let p): weightSum * CGFloat(p) / 100 - current
            case .addPercent(let p): weightSum * CGFloat(p) / 100
            case .subtractPercent(let p): -weightSum * CGFloat(p) / 100
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        // i3 refuses a resize that would leave the container or any sibling under 1px
        // (commands.c cmd_resize_tiling_width_height) — negative weights overlapped neighbours and
        // persisted until balance-sizes.
        let onePx = weightPerPx
        if current + diff < onePx {
            return .fail(io.err("Not resizing, container would end with less than 1px"))
        }
        if parent.children.contains(where: { $0 != node && $0.getWeight(orientation) - childDiff < onePx }) {
            return .fail(io.err("Not resizing, already at minimum size"))
        }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, current + diff)
        // Manual resize overrides any learned max-size cap — clear it so a stale/mis-learned cap
        // can't keep the window pinned; it re-learns if it still refuses to grow.
        for window in node.allLeafWindowsRecursive {
            window.learnedMaxSize = nil
        }
        return .succ
    }

    @MainActor
    private func resizeFloatingWindow(_ window: Window, _ io: CmdIo) async -> BinaryExitCode {
        guard let monitor = window.nodeMonitor else {
            return .fail(io.err("Window \(window.windowId) doesn't belong to any monitor"))
        }
        guard let rect = try? await window.intendedFrame(.nonCancellable) else {
            return .fail(io.err("Failed to get window \(window.windowId) frame"))
        }
        let full = monitor.visibleRect
        var width = rect.width
        var height = rect.height
        switch args.dimension.val {
            case .width:
                width = newDimension(current: rect.width, full: full.width)
            case .height:
                height = newDimension(current: rect.height, full: full.height)
            case .smart, .smartOpposite:
                width = newDimension(current: rect.width, full: full.width)
                height = newDimension(current: rect.height, full: full.height)
            case .left, .right:
                width = newDimension(current: rect.width, full: full.width)
            case .up, .down:
                height = newDimension(current: rect.height, full: full.height)
        }
        let size = CGSize(
            width: min(max(width, 10), full.width),
            height: min(max(height, 10), full.height),
        )
        // i3: growing a floating window's left/top edge moves its origin; right/bottom stay put
        let origin: CGPoint? = switch args.dimension.val {
            case .left: CGPoint(x: rect.topLeftX - (size.width - rect.width), y: rect.topLeftY)
            case .up: CGPoint(x: rect.topLeftX, y: rect.topLeftY - (size.height - rect.height))
            default: nil
        }
        window.requestFrame(topLeft: origin, size: size)
        return .succ
    }

    /// i3 resize_tiling_neighbors: the nearest ancestor-or-self with a sibling on `edge` inside a
    /// tiles container running that way trades space with that one sibling. i3 refuses a resize
    /// that would leave either under 1px.
    @MainActor
    private func resizeTowardNeighbour(_ subject: TreeNode, _ edge: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
        let o = edge.orientation
        guard let (node, parent, neighbour) = subject.parentsWithSelf.lazy.compactMap({ node -> (TreeNode, TilingContainer, TreeNode)? in
            guard let parent = node.parent as? TilingContainer, parent.orientation == o, parent.layout == .tiles,
                  let index = node.ownIndex, parent.children.indices.contains(index + edge.focusOffset)
            else { return nil }
            return (node, parent, parent.children[index + edge.focusOffset])
        }).first else {
            return .fail(io.err("No neighbour to resize against in direction '\(edge.rawValue)'"))
        }
        let weightSum = CGFloat(parent.children.sumOfDouble { $0.getWeight(o) })
        let weightPerPx = parent.weightPerPixel(o)
        let diff: CGFloat
        switch args.units.val {
            case .add(let px): diff = CGFloat(px) * weightPerPx
            case .subtract(let px): diff = -CGFloat(px) * weightPerPx
            case .addPercent(let p): diff = weightSum * CGFloat(p) / 100
            case .subtractPercent(let p): diff = -weightSum * CGFloat(p) / 100
            case .set, .setPercent: return .fail(io.err("Directional resize takes a relative amount (+N / -N)"))
        }
        let a = node.getWeight(o) + diff
        let b = neighbour.getWeight(o) - diff
        if a < weightPerPx || b < weightPerPx { return .fail(io.err("Not resizing, a container would end with less than 1px")) }
        node.setWeight(o, a)
        neighbour.setWeight(o, b)
        return .succ
    }

    private func newDimension(current: CGFloat, full: CGFloat) -> CGFloat {
        switch args.units.val {
            case .set(let unit): CGFloat(unit)
            case .add(let unit): current + CGFloat(unit)
            case .subtract(let unit): current - CGFloat(unit)
            case .setPercent(let unit): full * CGFloat(unit) / 100
            case .addPercent(let unit): current + full * CGFloat(unit) / 100
            case .subtractPercent(let unit): current - full * CGFloat(unit) / 100
        }
    }
}
