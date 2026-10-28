import Common
import CoreGraphics

extension Workspace {
    /// The size a tiling node **will** occupy, computed from the model alone.
    ///
    /// This exists so that decisions about STRUCTURE never read the output of layout. Placement used
    /// to consult `desiredRect`, which layout writes during the pass that runs *after* placement —
    /// a cycle. For a window that had not been laid out yet the value was simply absent, and the
    /// caller treated that absence as a signal rather than as "not computed yet", falling through to
    /// a different rule. That is how a workspace could flip from side-by-side to stacked.
    ///
    /// A tile's geometry is not a fact that must be observed; it is a deterministic function of the
    /// monitor rect, the tree shape, and the weights — all of which are model state. So it can be
    /// projected, and the "not laid out yet" case disappears rather than being handled.
    ///
    /// Mirrors `layoutPersistentTiles`: proportional weight shares along the parent's orientation.
    /// Deliberately ignores inner gaps and max-size caps — they shift a span by a few points and
    /// cannot change which side of square an aspect falls on, except for tiles that are already
    /// within a few points of square, where either split is equally defensible.
    ///
    /// nil when the node is not in this workspace's tiling tree (floating, minimized, hidden).
    @MainActor
    func projectedTileSize(of node: TreeNode) -> CGSize? {
        // Walk up to the root, recording which child we came from at each level.
        var steps: [(child: TreeNode, parent: TilingContainer)] = []
        var current: TreeNode = node
        while let parent = current.parent as? TilingContainer {
            steps.append((current, parent))
            current = parent
        }
        // `current` must now be the workspace's root tiling container, reached through tiling
        // parents only. Anything else (a float, a parked window) has no tile to project.
        guard current === rootTilingContainer else { return nil }

        var size = tilingRect.then {
            CGSize(width: $0.width, height: $0.height)
        }
        for (child, parent) in steps.reversed() {
            switch parent.layout {
                case .tiles, .master:
                    // Master's ratio math differs, but it still divides along the parent's
                    // orientation, so the aspect it yields is the same side of square in every case
                    // that matters here.
                    // `getWeight(parent.orientation)` returns the child's own weight when the
                    // orientation matches, which it does by construction here. Safe for every node
                    // reached by this walk: only tiling parents are traversed, and accordion —
                    // where weight is meaningless — is handled separately below.
                    let siblings = parent.children
                    let total = siblings.reduce(CGFloat(0)) { $0 + max($1.getWeight(parent.orientation), 0) }
                    let share = total > 0
                        ? max(child.getWeight(parent.orientation), 0) / total
                        : 1 / CGFloat(max(siblings.count, 1))
                    if parent.orientation == .h {
                        size.width *= share
                    } else {
                        size.height *= share
                    }
                case .accordion:
                    // Every child of an accordion occupies the whole container.
                    break
            }
        }
        return size
    }

    /// Whether a new tile placed beside `node` should split it side-by-side.
    ///
    /// Dwindle's policy is "split by the tile's aspect ratio". Asking the model rather than the last
    /// layout pass means the answer exists for a window that has never been laid out — the case that
    /// used to fall through to perpendicular-to-parent alternation and, once dwindle's
    /// single-child flattening promoted the wrapper to root, flipped the whole workspace.
    @MainActor
    func shouldSplitSideBySide(beside node: TreeNode) -> Bool {
        guard let size = projectedTileSize(of: node) else {
            // Not a tile: fall back to the workspace's own shape, still model state.
            let r = tilingRect
            return r.width > r.height
        }
        return size.width > size.height
    }
}
