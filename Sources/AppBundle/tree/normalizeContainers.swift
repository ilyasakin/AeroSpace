extension Workspace {
    @MainActor func normalizeContainers() {
        let dwindle = effectiveTilingPolicy == .dwindle
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
        if let child = children.singleOrNil(), (config.enableNormalizationFlattenContainers || forceFlattenSingleChild) && (child is TilingContainer || !isRootContainer) {
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
