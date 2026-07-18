import AppKit
import Common

struct ToggleGroupCommand: Command {
    let args: ToggleGroupCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let parent = window.parent as? TilingContainer else {
            return .fail(io.err("toggle-group requires a tiled window"))
        }

        // Already in an accordion group → unwrap
        if parent.layout == .accordion {
            if let grand = parent.parent as? TilingContainer {
                let parentIndex = parent.ownIndex.orDie()
                let kids = Array(parent.children)
                var weights: [CGFloat] = []
                for child in kids {
                    weights.append(child.getWeight(parent.orientation))
                    _ = child.unbindFromParent()
                }
                _ = parent.unbindFromParent()
                var insertAt = parentIndex
                for (child, weight) in zip(kids, weights) {
                    child.bind(to: grand, adaptiveWeight: weight, index: insertAt)
                    insertAt += 1
                }
                return .succ
            } else if parent.parent is Workspace {
                // Root accordion: convert to tiles
                parent.layout = .tiles
                return .succ
            }
            return .fail(io.err("can't unwrap this group"))
        }

        // Wrap focused window in a new accordion group.
        // Single-member groups are preserved by normalizeContainers (accordion exempt from flatten);
        // the next placed window is absorbed into the group via commitTilingPlaceNewWindow.
        let data = window.unbindFromParent()
        let group = TilingContainer(
            parent: parent,
            adaptiveWeight: data.adaptiveWeight,
            parent.orientation,
            .accordion,
            index: data.index,
        )
        window.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: 0)
        window.markAsMostRecentChild()
        return .succ
    }
}
