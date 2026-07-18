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

    /// Place a newly detected / re-tiled window into the tiling spine (dwindle or beside MRU).
    /// Path-copy first; live dual-link is rebuilt by materialize. Window handle must already exist.
    ///
    /// If the placement target sits in an accordion **group** (`toggle-group`), the new window is
    /// absorbed into that group (Hyprland togglegroup "next window joins the group") instead of
    /// dwindling or splitting outside it.
    @discardableResult
    func commitTilingPlaceNewWindow(id: UInt32) -> Bool {
        let focusedTiling: Window? = focus.windowOrNil?.takeIf {
            $0.windowId != id && $0.nodeWorkspace == self && $0.parent is TilingContainer
        }
        let mru = rootTilingContainer.mostRecentWindowRecursive
        let target = focusedTiling ?? mru

        // Absorb into accordion group when focus/MRU is a group member
        if let target,
           target.windowId != id,
           let group = target.parent as? TilingContainer,
           group.layout == .accordion
        {
            let absorbId = target.windowId
            let ok = commitTilingTransform { spine in
                spine.insertWindowBeside(besideId: absorbId, newId: id, weight: 1)
            }
            if ok {
                Window.get(byId: absorbId)?.markAsMostRecentChild()
            }
            return ok
        }

        if effectiveTilingPolicy == .dwindle,
           let target,
           target.windowId != id
        {
            let rect = target.lastAppliedLayoutPhysicalRect
            let splitHorizontal = rect.map { $0.width > $0.height }
                ?? ((target.parent as? TilingContainer)?.orientation == .v)
            let ratio = CGFloat(config.dwindleSplitPercent) / 100
            let ok = commitTilingTransform { spine in
                // Target must already be in the spine; empty workspace falls through to insert
                spine.dwindleSplit(
                    targetId: target.windowId,
                    newId: id,
                    splitHorizontal: splitHorizontal,
                    ratio: ratio,
                ) ?? spine.insertWindowBeside(besideId: nil, newId: id, weight: 1)
            }
            if ok {
                Window.get(byId: target.windowId)?.markAsMostRecentChild()
            }
            return ok
        }

        let besideId = mru?.takeIf { $0.windowId != id }?.windowId
        return commitTilingTransform { spine in
            spine.insertWindowBeside(besideId: besideId, newId: id, weight: 1)
        }
    }

    /// Swap two tiling windows: path-copy the generation first, then dual-link swap in place
    /// (avoids full materialize so live identity/MRU stay stable).
    @discardableResult
    func commitTilingSwap(id1: UInt32, id2: UInt32) -> Bool {
        guard let w1 = Window.get(byId: id1), let w2 = Window.get(byId: id2),
              w1.parent is TilingContainer, w2.parent is TilingContainer
        else { return false }
        let before = tilingStructureGeneration ?? PersistentTilingNode.capture(rootTilingContainer)
        guard let after = before.swappingWindows(id1: id1, id2: id2) else { return false }
        unsafe Workspace.suppressTilingGenerationInvalidation = true
        let binding2 = w2.unbindFromParent()
        let binding1 = w1.unbindFromParent()
        w2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
        w1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
        unsafe Workspace.suppressTilingGenerationInvalidation = false
        tilingStructureGeneration = after
        return true
    }

    /// Sibling reorder: path-copy generation first, then dual-link rebind in place.
    @discardableResult
    func commitTilingMoveWindow(_ id: UInt32, toIndexInParent index: Int) -> Bool {
        guard let window = Window.get(byId: id),
              let parent = window.parent as? TilingContainer
        else { return false }
        let before = tilingStructureGeneration ?? PersistentTilingNode.capture(rootTilingContainer)
        guard let after = before.movingWindow(id, toIndexInParent: index) else { return false }
        unsafe Workspace.suppressTilingGenerationInvalidation = true
        let prev = window.unbindFromParent()
        window.bind(to: parent, adaptiveWeight: prev.adaptiveWeight, index: index)
        unsafe Workspace.suppressTilingGenerationInvalidation = false
        tilingStructureGeneration = after
        return true
    }

    /// Rebuild the live dual-link tiling root from an immutable spine.
    /// Windows are resolved by id; unit-test windows are parked floating first so `Window.get` finds them.
    ///
    /// Always publishes `tilingStructureGeneration = spine`. After session restore, discovery layout
    /// may have left a **stale** generation; layout trusts that gen when present, so without this
    /// publish the next layout would re-apply the pre-restore structure (e.g. horizontal tiles
    /// after a vertical restore).
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
        tilingStructureGeneration = spine
    }

    /// Dirty-flag protocol: if a generation is published, trust it. If nil, capture from live
    /// dual-link tree. Dual-link structure/weight mutations must call
    /// `invalidateTilingStructureGeneration()` so the next layout recaptures. No equality guessing.
    func currentTilingSpine() -> PersistentTilingNode {
        if let gen = tilingStructureGeneration {
            return gen
        }
        let captured = PersistentTilingNode.capture(rootTilingContainer)
        tilingStructureGeneration = captured
        return captured
    }
}
