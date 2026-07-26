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
                // Weight SCALES differ between the group and its destination, and carrying the
                // group's child weights across unchanged produced invisible slivers.
                //
                // Tiles containers have their child weights renormalized to spans by layout
                // (~hundreds of px); accordion containers never normalize theirs, so accordion
                // children keep their authored ratio scale (~1). Binding a weight-1 child in
                // beside weight-800 siblings gives it 1/1600th of the span. (The old additive
                // normalization masked this by equalizing everything; proportional normalization
                // faithfully renders the mismatch.)
                //
                // Correct semantics: the group occupied ONE slot in `grand`, so its children
                // subdivide exactly that slot, keeping their relative proportions.
                let groupWeight = parent.getWeight(grand.orientation)
                let childWeights = kids.map { $0.getWeight(parent.orientation) }
                let weightSum = childWeights.reduce(0, +)
                let rescaled: [CGFloat] = weightSum > 0
                    ? childWeights.map { groupWeight * $0 / weightSum }
                    : Array(repeating: groupWeight / CGFloat(max(kids.count, 1)), count: kids.count)
                for child in kids {
                    _ = child.unbindFromParent()
                }
                _ = parent.unbindFromParent()
                var insertAt = parentIndex
                for (child, weight) in zip(kids, rescaled) {
                    child.bind(to: grand, adaptiveWeight: weight, index: insertAt)
                    insertAt += 1
                }
                return .succ
            } else if parent.parent is Workspace {
                // Root accordion: convert to tiles
                parent.setLayout(.tiles)
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
