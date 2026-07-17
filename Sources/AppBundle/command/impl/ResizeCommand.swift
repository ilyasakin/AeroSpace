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
        if args.units.val.isPercent {
            return .fail(io.err("Percent units are currently supported only for floating windows"))
        }

        let candidates = target.windowOrNil?.parentsWithSelf
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
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
            case .setPercent, .addPercent, .subtractPercent: dieT("Percent units are rejected above for tiling windows")
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }

    @MainActor
    private func resizeFloatingWindow(_ window: Window, _ io: CmdIo) async -> BinaryExitCode {
        guard let monitor = window.nodeMonitor else {
            return .fail(io.err("Window \(window.windowId) doesn't belong to any monitor"))
        }
        guard let rect = try? await window.getAxRect(.nonCancellable) else {
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
        }
        let size = CGSize(
            width: min(max(width, 10), full.width),
            height: min(max(height, 10), full.height),
        )
        window.setAxFrame(nil, size)
        window.lastFloatingSize = size
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
