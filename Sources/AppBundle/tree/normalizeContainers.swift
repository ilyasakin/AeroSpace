import AppKit
extension Workspace {
    @MainActor func normalizeContainers() {
        let dwindle = effectiveTilingPolicy == .dwindle
        if config.i3Normalization && !dwindle {
            rootTilingContainer.i3Normalize()
            return
        }
        // Dwindle must always collapse single-child containers (closing one half of a binary
        // split leaves a wrapper behind), independently of the flatten-containers setting
        rootTilingContainer.unbindEmptyAndAutoFlatten(forceFlattenSingleChild: dwindle) // Beware! rootTilingContainer may change after this line of code
        // Dwindle chooses orientations by tile aspect ratio; don't force alternation over them
        if config.enableNormalizationOppositeOrientationForNestedContainers && !dwindle {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten(forceFlattenSingleChild: Bool = false) {
        // Accordion groups (toggle-group) must survive as single-child containers until a second
        // member is absorbed or the user unwraps. Flattening them would make toggle-group a no-op
        // under enable-normalization-flatten-containers (the default).
        let mayFlattenSingleChild = layout != .accordion
            && (config.enableNormalizationFlattenContainers || forceFlattenSingleChild)
        if let child = children.singleOrNil(),
           mayFlattenSingleChild
           && (child is TilingContainer || !isRootContainer)
        {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(forceFlattenSingleChild: forceFlattenSingleChild)
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(forceFlattenSingleChild: forceFlattenSingleChild)
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}

extension TilingContainer {
    /// i3 normalization (tree.c `tree_flatten` + closing empty containers), instead of AeroSpace's
    /// "flatten every single-child container" / "alternate orientations":
    /// - empty containers close;
    /// - a single-child container holding a WINDOW is kept (that is what `split` creates);
    /// - only a redundant pair collapses: a tiles container whose one child is a tiles container of
    ///   the other orientation that matches the grandparent's — the child's children take the
    ///   container's place (move sequences across orientations used to pile these up).
    @MainActor fileprivate func i3Normalize() {
        for child in children {
            (child as? TilingContainer)?.i3Normalize()
        }
        if children.isEmpty {
            if !isRootContainer { unbindFromParent() }
            return
        }
        guard let grandparent = parent as? TilingContainer, layout == .tiles,
              let only = children.singleOrNil() as? TilingContainer, only.layout == .tiles,
              only.orientation != orientation, only.orientation == grandparent.orientation,
              let index = ownIndex
        else { return }
        let o = grandparent.orientation
        let share = getWeight(o)
        let innerSum = only.children.sumOfDouble { $0.getWeight(o) }
        // Whole-workspace order: re-marking only this branch would make it the workspace's
        // most recent one (i3 tree_flatten edits the parent's focus stack locally)
        let focusOrder = nodeWorkspace?.windowsInFocusOrder ?? grandparent.windowsInFocusOrder
        let grandchildren = only.children
        unbindFromParent()
        for (i, node) in grandchildren.enumerated() {
            let w = node.getWeight(o)
            let scaled = innerSum > 0 ? share * CGFloat(w / innerSum) : share / CGFloat(grandchildren.count)
            node.bind(to: grandparent, adaptiveWeight: scaled, index: index + i)
        }
        for w in focusOrder.reversed() { w.markAsMostRecentChild() }
    }
}
