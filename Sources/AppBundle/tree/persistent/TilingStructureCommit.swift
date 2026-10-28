import Common
import CoreGraphics

/// Structural commits: a pure transform of a snapshot of the tiling tree (well tested on values),
/// applied back onto the one tree. The snapshot is taken fresh for every commit — nothing is cached.
@MainActor
extension Workspace {
    /// Apply a pure path-copy transform to the tiling spine, then materialize live handles.
    /// Returns false if the transform fails (invalid path / shape).
    @discardableResult
    func commitTilingTransform(
        _ context: @autoclosure () -> String = "commitTilingTransform",
        _ transform: (PersistentTilingNode) -> PersistentTilingNode?,
    ) -> Bool {
        guard let after = transform(currentTilingSpine()) else { return false }
        materializeTilingSpine(after)
        return true
    }

    /// Insert a tiling window leaf into the root container via path-copy, then materialize.
    /// Window must already exist as a live handle (any parent); materialize rebinds it.
    @discardableResult
    func commitTilingInsertWindow(id: UInt32, weight: CGFloat = 1, at index: Int = INDEX_BIND_LAST) -> Bool {
        commitTilingTransform("insertWindow") { spine in
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
        commitTilingTransform("removeWindow") { spine in
            guard let path = spine.path(ofWindowId: id) else { return nil }
            return spine.removing(at: path)?.root
        }
    }

    /// Call BEFORE a tiled window leaves tiling (float, minimize, native fullscreen, app hide, tab
    /// park): remembers its slot and the exact spine. No-op for a window that isn't tiled.
    func captureTileRestorePoint(for window: Window) {
        guard window.parent is TilingContainer, window.nodeWorkspace === self else { return }
        window.tileRestoreSlot = FloatingRestoreSlot.capture(from: window)
        window.tileRestorePreSpine = currentTilingSpine()
        window.tileRestorePostSpine = nil
        tileRestoreSequenceCounter &+= 1
        window.tileRestoreSequence = tileRestoreSequenceCounter
    }

    /// Call right AFTER the window was unbound from tiling: settle the flatten now and snapshot the
    /// result, so the restore-time comparison baseline matches what refresh-time normalization
    /// will produce.
    func settleTileRestorePoint(for window: Window) {
        guard window.tileRestorePreSpine != nil else { return }
        normalizeContainers()
        window.tileRestorePostSpine = currentTilingSpine()
    }

    /// Put a window that left tiling back where it was (i3: floating toggle / unminimize never
    /// scramble sibling order). Tiers: (1) nothing changed meanwhile → the pre-removal spine
    /// verbatim; (2) original neighbour slot; (3) i3 `floating_disable` — plain sibling after the
    /// MRU tiling leaf. Returns false only if all tiers failed (caller falls back to placement).
    func restoreTile(_ window: Window) -> Bool {
        let preSpine = window.tileRestorePreSpine
        let postSpine = window.tileRestorePostSpine
        let slot = window.tileRestoreSlot
        window.tileRestorePreSpine = nil
        window.tileRestorePostSpine = nil
        window.tileRestoreSlot = nil
        window.tileRestoreSequence = 0
        // Commits place a window that sits in this workspace's floating layer (same contract as
        // new-window placement); a window coming back from a macOS container is moved there first.
        if !(window.parent is FloatingWindowsContainer && window.nodeWorkspace === self) {
            window.bindAsFloatingWindow(to: self)
        }
        // Full equality, weights included (they are the model's, layout no longer rewrites them):
        // a resize made while the window was away must not be undone by restoring the old spine
        if let preSpine, let postSpine, currentTilingSpine() == postSpine {
            materializeTilingSpine(preSpine)
            if window.parent is TilingContainer { return true }
        }
        if let slot, slot.workspaceName == name,
           commitTilingRestoreFloatingSlot(windowId: window.windowId, slot: slot)
        {
            return true
        }
        return commitTilingUnfloat(windowId: window.windowId)
    }

    /// Re-insert a window that was floated from tiling, preferring its original neighbor slots
    /// (i3 floating toggle: unfloat does not scramble sibling order). Neighbor leaves inside
    /// container siblings resolve via the recorded ascent (see FloatingRestoreSlot). Returns
    /// false when neither neighbor resolves — caller falls back to `commitTilingUnfloat`.
    @discardableResult
    func commitTilingRestoreFloatingSlot(windowId: UInt32, slot: FloatingRestoreSlot) -> Bool {
        commitTilingTransform("restoreFloatingSlot") { spine in
            // Drop if somehow still present (stale gen).
            let base = spine.path(ofWindowId: windowId).flatMap { spine.removing(at: $0)?.root } ?? spine
            // The slot's share of the container, on the destination container's own weight scale
            func child(in containerPath: PersistentPath) -> PersistentTilingNode {
                let siblings: [PersistentTilingNode] = if case .container(_, _, _, let c, _)? = base.node(at: containerPath) { c } else { [] }
                let sum = siblings.reduce(CGFloat(0)) { $0 + max($1.weight, 0) }
                let share = min(max(slot.share, 0.01), 0.9)
                let weight = sum > 0 ? share * sum / (1 - share) : 1
                return .window(id: windowId, weight: weight)
            }
            if let afterId = slot.neighborAfterId,
               let leafPath = base.path(ofWindowId: afterId),
               !leafPath.isRoot
            {
                let sibling = leafPath.ascending(by: slot.neighborAfterAscent)
                if let idx = sibling.indices.last {
                    return base.inserting(child: child(in: sibling.dropLast), at: idx, intoContainerAt: sibling.dropLast)
                }
            }
            if let beforeId = slot.neighborBeforeId,
               let leafPath = base.path(ofWindowId: beforeId),
               !leafPath.isRoot
            {
                let sibling = leafPath.ascending(by: slot.neighborBeforeAscent)
                if let idx = sibling.indices.last {
                    return base.inserting(child: child(in: sibling.dropLast), at: idx + 1, intoContainerAt: sibling.dropLast)
                }
            }
            return nil
        }
    }

    /// i3 `floating_disable` 1:1 (src/floating.c): re-insert AFTER the workspace's most recently
    /// focused tiling leaf (`con_descend_tiling_focused` skips floats) as its plain sibling with
    /// reset weight — no dwindle split, no restore guesswork. Empty workspace → attach to root.
    @discardableResult
    func commitTilingUnfloat(windowId: UInt32) -> Bool {
        let mruId = rootTilingContainer.mostRecentWindowRecursive?
            .takeIf { $0.windowId != windowId }?.windowId
        return commitTilingTransform("unfloat") { spine in
            let base = spine.path(ofWindowId: windowId).flatMap { spine.removing(at: $0)?.root } ?? spine
            if let mruId,
               let path = base.path(ofWindowId: mruId),
               !path.isRoot,
               let idx = path.indices.last
            {
                let parentPath = path.dropLast
                // Average-of-siblings weight: weights are proportions on each container's own scale,
                // so i3's "reset percent" maps to an equal share, not 1
                let weight = base.averageChildWeight(ofContainerAt: parentPath)
                return base.inserting(child: .window(id: windowId, weight: weight), at: idx + 1, intoContainerAt: parentPath)
            }
            let weight = base.averageChildWeight(ofContainerAt: .root)
            return base.inserting(child: .window(id: windowId, weight: weight), at: INDEX_BIND_LAST, intoContainerAt: .root)
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
            let ok = commitTilingTransform("placeNewWindow.absorbGroup") { spine in
                spine.insertWindowBeside(besideId: absorbId, newId: id)
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
            // Dwindle chooses the split by TILE ASPECT. The aspect is PROJECTED from the model
            // (monitor rect + tree shape + weights), never read from the previous layout pass —
            // see `projectedTileSize`. Reading layout output here was a cycle: placement consumed a
            // value that layout writes afterwards, so for a window not yet laid out it was absent,
            // and the absent case fell through to perpendicular-to-parent alternation. Inside a
            // horizontal root that yields a vertical wrapper, which dwindle's single-child
            // flattening then promotes to root — the whole workspace flipping to stacked.
            let splitHorizontal = shouldSplitSideBySide(beside: target)
            let ratio = CGFloat(config.dwindleSplitPercent) / 100
            let ok = commitTilingTransform("placeNewWindow.dwindle") { spine in
                // Target must already be in the spine; empty workspace falls through to insert
                spine.dwindleSplit(
                    targetId: target.windowId,
                    newId: id,
                    splitHorizontal: splitHorizontal,
                    ratio: ratio,
                ) ?? spine.insertWindowBeside(besideId: nil, newId: id)
            }
            if ok {
                Window.get(byId: target.windowId)?.markAsMostRecentChild()
            }
            return ok
        }

        let besideId = mru?.takeIf { $0.windowId != id }?.windowId
        return commitTilingTransform("placeNewWindow.beside") { spine in
            spine.insertWindowBeside(besideId: besideId, newId: id)
        }
    }

    /// Swap two tiling windows: path-copy the generation first, then dual-link swap in place
    /// (avoids full materialize so live identity/MRU stay stable).
    @discardableResult
    func commitTilingSwap(id1: UInt32, id2: UInt32) -> Bool {
        guard let w1 = Window.get(byId: id1), let w2 = Window.get(byId: id2),
              w1.parent is TilingContainer, w2.parent is TilingContainer
        else { return false }
        guard currentTilingSpine().swappingWindows(id1: id1, id2: id2) != nil else { return false }
        let binding2 = w2.unbindFromParent()
        let binding1 = w1.unbindFromParent()
        w2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
        w1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
        return true
    }

    /// Sibling reorder: path-copy generation first, then dual-link rebind in place.
    @discardableResult
    func commitTilingMoveWindow(_ id: UInt32, toIndexInParent index: Int) -> Bool {
        guard let window = Window.get(byId: id),
              let parent = window.parent as? TilingContainer
        else { return false }
        guard currentTilingSpine().movingWindow(id, toIndexInParent: index) != nil else { return false }
        let prev = window.unbindFromParent()
        window.bind(to: parent, adaptiveWeight: prev.adaptiveWeight, index: index)
        return true
    }

    /// Apply a transformed snapshot back onto the tree. Windows are resolved by id through the
    /// registry, so unbinding the old root does not make them unresolvable. Leaves naming dead
    /// windows are skipped.
    func materializeTilingSpine(_ spine: PersistentTilingNode) {
        let oldRoot = rootTilingContainer
        let leaves = oldRoot.allLeafWindowsRecursive
        // Rebinding children re-orders MRU stacks (bind order = last child becomes MRU), which
        // flips accordion fronts, misroutes close-focus and directional focus into a neighbour
        // container, and breaks the fullscreen gate (`mostRecentWindowRecursive`). Capture the
        // workspace's focus order and replay it after (floats keep their rank relative to tiling).
        let focusOrder = windowsInFocusOrder.map(\.windowId)
        // Every container of the old tree, detached and emptied: the snapshot's containers are
        // re-created from these by id (identity kept), and only new ones are built
        var reusable: [UInt64: TilingContainer] = [:]
        func collect(_ container: TilingContainer) {
            reusable[container.nodeId] = container
            for case let nested as TilingContainer in container.children { collect(nested) }
        }
        collect(oldRoot)
        oldRoot.unbindFromParent()
        // Drop any other residual tiling containers under the workspace
        for child in children {
            if let residual = child as? TilingContainer {
                collect(residual)
                residual.unbindFromParent()
            }
        }
        // Emptied completely: a window the snapshot leaves out must not stay tiled in a reused
        // container (it ends unbound, as it did under the old detached root)
        for container in reusable.values {
            for child in Array(container.children) { child.unbindFromParent() }
        }
        if !spine.restore(parent: self, index: INDEX_BIND_LAST, reusing: reusable) {
            // Entirely stale spine (every id dead/unbindable) — a WM must degrade, not die.
            // Re-bind the previous leaves so no window is orphaned
            for window in leaves where window.parent == nil || window.parent === oldRoot {
                window.bind(to: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
        for id in focusOrder.reversed() {
            if let w = Window.get(byId: id), w.nodeWorkspace === self { w.markAsMostRecentChild() }
        }
    }

    /// A snapshot of the tiling tree as it is now (value; taken fresh, never cached)
    func currentTilingSpine() -> PersistentTilingNode {
        PersistentTilingNode.capture(rootTilingContainer)
    }
}

@MainActor private var tileRestoreSequenceCounter: UInt64 = 0
