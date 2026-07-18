import Common
import CoreGraphics

/// Path-copy-first structural commits for the tiling spine (#1215 cutover).
///
/// Order is load-bearing:
/// 1. Read current generation (or capture once if missing)
/// 2. Apply pure path-copy transform → new spine
/// 3. Materialize live dual-link handles from the new spine
/// 4. Publish generation
///
/// Live tree is never the mutation source of truth for structure on this path.
@MainActor
extension Workspace {
    /// Apply a pure path-copy transform to the tiling spine, then materialize live handles.
    /// Returns false if the transform fails (invalid path / shape).
    @discardableResult
    func commitTilingTransform(_ transform: (PersistentTilingNode) -> PersistentTilingNode?) -> Bool {
        let before = tilingStructureGeneration ?? PersistentTilingNode.capture(rootTilingContainer)
        guard let after = transform(before) else { return false }
        materializeTilingSpine(after)
        tilingStructureGeneration = after
        return true
    }

    /// Insert a tiling window leaf into the root container via path-copy, then materialize.
    /// Window must already exist as a live handle (any parent); materialize rebinds it.
    @discardableResult
    func commitTilingInsertWindow(id: UInt32, weight: CGFloat = 1, at index: Int = INDEX_BIND_LAST) -> Bool {
        commitTilingTransform { spine in
            spine.inserting(
                child: .window(id: id, weight: weight),
                at: index,
                intoContainerAt: .root,
            )
        }
    }

    /// Remove a window leaf from the tiling spine via path-copy, then materialize.
    @discardableResult
    func commitTilingRemoveWindow(id: UInt32) -> Bool {
        commitTilingTransform { spine in
            guard let path = spine.path(ofWindowId: id) else { return nil }
            return spine.removing(at: path)?.root
        }
    }

    /// Rebuild the live dual-link tiling root from an immutable spine.
    /// Windows are resolved by id; unit-test windows are parked floating first so `Window.get` finds them.
    func materializeTilingSpine(_ spine: PersistentTilingNode) {
        let oldRoot = rootTilingContainer
        let leaves = oldRoot.allLeafWindowsRecursive
        oldRoot.unbindFromParent()
        // Test lookup walks workspace leaves only — park ids so restore can rebind
        if isUnitTest {
            for window in leaves {
                window.bindAsFloatingWindow(to: self)
            }
        }
        // Drop any other residual tiling containers under the workspace
        for child in children {
            if child is TilingContainer {
                child.unbindFromParent()
            }
        }
        check(spine.restore(parent: self, index: INDEX_BIND_LAST), "Failed to materialize tiling spine")
    }

    /// Spine for layout: must match **full** live structure (order, nesting, weights), not just the
    /// window-id set. Dual-link mutators (swap/move/reparent) can reorder the same ids; comparing
    /// only membership would keep a stale generation and undo the live tree on the next layout.
    func currentTilingSpine() -> PersistentTilingNode {
        let captured = PersistentTilingNode.capture(rootTilingContainer)
        if let gen = tilingStructureGeneration, gen == captured {
            return gen
        }
        tilingStructureGeneration = captured
        return captured
    }

}
