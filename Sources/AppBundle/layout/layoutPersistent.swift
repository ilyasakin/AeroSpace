import AppKit
import Common

/// Tiling layout driven by the immutable persistent spine (#1215 cutover).
///
/// Structure and weights for geometry come only from `PersistentTilingNode`. Windows are
/// resolved by id for AX writes. There is no spine/`liveChildren[i]` index pairing for
/// geometry or weight distribution. Accordion MRU consults live focus metadata (most-recent
/// window id) only to pick which spine sibling is "front."
///
/// Structural mutations that go through `commitTilingTransform` update the generation first;
/// layout reads that generation (or recaptures if membership drifted).

extension Workspace {
    /// Last tiling spine used for layout / commits (updated each layout or commit).
    /// nonisolated(unsafe): dual-link bind/unbind may invalidate off the typed MainActor boundary
    /// while still running on the main thread under AeroSpace's session model.
    private nonisolated(unsafe) static var _tilingSpineByName: [String: PersistentTilingNode] = [:]

    var tilingStructureGeneration: PersistentTilingNode? {
        get { unsafe Self._tilingSpineByName[name] }
        set {
            if let newValue {
                unsafe Self._tilingSpineByName[name] = newValue
            } else {
                unsafe Self._tilingSpineByName.removeValue(forKey: name)
            }
        }
    }

    /// Drop cached spines (tests / workspace GC hygiene)
    static func clearTilingStructureGenerations() {
        unsafe _tilingSpineByName.removeAll(keepingCapacity: true)
    }

    /// Dual-link bind/unbind must clear the published spine so layout recaptures live order.
    func invalidateTilingStructureGeneration() {
        tilingStructureGeneration = nil
    }

    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        let context = LayoutContext(self)
        let physicalRect = Rect(
            topLeftX: rect.topLeftX,
            topLeftY: rect.topLeftY,
            width: rect.width,
            height: rect.height - 1,
        )
        lastAppliedLayoutPhysicalRect = physicalRect
        lastAppliedLayoutVirtualRect = rect

        // Prefer committed generation; recapture only on membership drift
        let spine = currentTilingSpine()
        let mruWindowId = rootTilingContainer.mostRecentWindowRecursive?.windowId

        let laidOut = try await layoutPersistentNode(
            spine,
            point: physicalRect.topLeftCorner,
            width: physicalRect.width,
            height: physicalRect.height,
            virtual: rect,
            context: context,
            mruWindowId: mruWindowId,
        )
        // Publish weight-adjusted spine so the next pass does not re-capture from dual-link
        tilingStructureGeneration = laidOut
        // Keep live adaptive weights in sync for mouse helpers (by window id, not child index)
        applyWindowWeightsFromSpine(laidOut, parentOrientation: nil)

        try await layoutFloatingChildren(context: context)
    }

    @MainActor
    fileprivate func layoutFloatingChildren(context: LayoutContext) async throws {
        for window in floatingWindows {
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            try await window.layoutFloatingWindow(context)
        }
    }
}

/// Apply spine leaf weights onto live windows by id (no index pairing).
@MainActor
private func applyWindowWeightsFromSpine(_ node: PersistentTilingNode, parentOrientation: Orientation?) {
    switch node {
        case .window(let id, let weight):
            guard let parentOrientation,
                  let window = Window.get(byId: id),
                  window.parent is TilingContainer
            else { return }
            window.setWeight(parentOrientation, weight)
        case .container(let orientation, _, _, let children):
            for child in children {
                applyWindowWeightsFromSpine(child, parentOrientation: orientation)
            }
    }
}

/// Returns a weight-adjusted spine for the laid-out generation (path-copy of containers with new child weights).
@MainActor
private func layoutPersistentNode(
    _ node: PersistentTilingNode,
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    context: LayoutContext,
    mruWindowId: UInt32?,
) async throws -> PersistentTilingNode {
    let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)

    switch node {
        case .window(let id, let weight):
            guard let window = Window.get(byId: id) else { return node }
            if window.windowId == currentlyManipulatedWithMouseWindowId { return node }
            window.lastAppliedLayoutVirtualRect = virtual
            if window.isFullscreen,
               window == context.workspace.rootTilingContainer.mostRecentWindowRecursive
            {
                window.lastAppliedLayoutPhysicalRect = nil
                window.layoutFullscreen(context)
            } else {
                let prev = window.lastAppliedLayoutPhysicalRect
                window.lastAppliedLayoutPhysicalRect = physicalRect
                window.isFullscreen = false
                if prev != physicalRect {
                    window.setAxFrame(point, CGSize(width: width, height: height))
                }
            }
            return .window(id: id, weight: weight)

        case .container(let orientation, let layout, let weight, let children):
            switch layout {
                case .tiles:
                    return try await layoutPersistentTiles(
                        orientation: orientation,
                        layout: layout,
                        weight: weight,
                        children: children,
                        point: point,
                        width: width,
                        height: height,
                        virtual: virtual,
                        context: context,
                        mruWindowId: mruWindowId,
                    )
                case .accordion:
                    return try await layoutPersistentAccordion(
                        orientation: orientation,
                        layout: layout,
                        weight: weight,
                        children: children,
                        point: point,
                        width: width,
                        height: height,
                        virtual: virtual,
                        context: context,
                        mruWindowId: mruWindowId,
                    )
            }
    }
}

@MainActor
private func layoutPersistentTiles(
    orientation: Orientation,
    layout: Layout,
    weight: CGFloat,
    children: [PersistentTilingNode],
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    context: LayoutContext,
    mruWindowId: UInt32?,
) async throws -> PersistentTilingNode {
    guard !children.isEmpty else {
        return .container(orientation: orientation, layout: layout, weight: weight, children: children)
    }
    let weightSum = CGFloat(children.sumOfDouble { Double($0.weight) })
    let span = orientation == .h ? width : height
    guard let delta = (span - weightSum).div(children.count) else {
        return .container(orientation: orientation, layout: layout, weight: weight, children: children)
    }

    var point = point
    var virtualPoint = virtual.topLeftCorner
    let lastIndex = children.indices.last
    let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
    var newChildren: [PersistentTilingNode] = []
    newChildren.reserveCapacity(children.count)

    for (i, child) in children.enumerated() {
        let adjustedWeight = child.weight + delta
        let adjustedChild = child.withWeight(adjustedWeight)

        let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
        let childPoint = i == 0 ? point : point.addingOffset(orientation, rawGap / 2)
        let childWidth = orientation == .h ? adjustedWeight - gap : width
        let childHeight = orientation == .v ? adjustedWeight - gap : height
        let childVirtual = Rect(
            topLeftX: virtualPoint.x,
            topLeftY: virtualPoint.y,
            width: orientation == .h ? adjustedWeight : width,
            height: orientation == .v ? adjustedWeight : height,
        )
        let laidOut = try await layoutPersistentNode(
            adjustedChild,
            point: childPoint,
            width: childWidth,
            height: childHeight,
            virtual: childVirtual,
            context: context,
            mruWindowId: mruWindowId,
        )
        newChildren.append(laidOut)
        virtualPoint = orientation == .h
            ? virtualPoint.addingXOffset(adjustedWeight)
            : virtualPoint.addingYOffset(adjustedWeight)
        point = orientation == .h
            ? point.addingXOffset(adjustedWeight)
            : point.addingYOffset(adjustedWeight)
    }
    return .container(orientation: orientation, layout: layout, weight: weight, children: newChildren)
}

@MainActor
private func layoutPersistentAccordion(
    orientation: Orientation,
    layout: Layout,
    weight: CGFloat,
    children: [PersistentTilingNode],
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    context: LayoutContext,
    mruWindowId: UInt32?,
) async throws -> PersistentTilingNode {
    // MRU among this container's spine children — live focus metadata only (window id), not child index of dual-link
    let mruIndex: Int = {
        guard let mruWindowId else { return 0 }
        if let i = children.firstIndex(where: { child in
            switch child {
                case .window(let id, _): id == mruWindowId
                case .container: child.windowIds.contains(mruWindowId)
            }
        }) { return i }
        return 0
    }()
    let lastIndex = children.indices.last
    var newChildren: [PersistentTilingNode] = []
    newChildren.reserveCapacity(children.count)

    for (index, child) in children.enumerated() {
        let padding = CGFloat(config.accordionPadding)
        let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
            case 0 where children.count == 1: (0, 0)
            case 0: (0, padding)
            case lastIndex: (padding, 0)
            case mruIndex - 1: (0, 2 * padding)
            case mruIndex + 1: (2 * padding, 0)
            default: (padding, padding)
        }
        let laidOut: PersistentTilingNode
        switch orientation {
            case .h:
                laidOut = try await layoutPersistentNode(
                    child,
                    point: point + CGPoint(x: lPadding, y: 0),
                    width: width - rPadding - lPadding,
                    height: height,
                    virtual: virtual,
                    context: context,
                    mruWindowId: mruWindowId,
                )
            case .v:
                laidOut = try await layoutPersistentNode(
                    child,
                    point: point + CGPoint(x: 0, y: lPadding),
                    width: width,
                    height: height - lPadding - rPadding,
                    virtual: virtual,
                    context: context,
                    mruWindowId: mruWindowId,
                )
        }
        newChildren.append(laidOut)
    }
    return .container(orientation: orientation, layout: layout, weight: weight, children: newChildren)
}

extension PersistentTilingNode {
    /// Shallow weight update (does not recurse into container children).
    fileprivate func withWeight(_ newWeight: CGFloat) -> PersistentTilingNode {
        switch self {
            case .window(let id, _): .window(id: id, weight: newWeight)
            case .container(let o, let l, _, let c): .container(orientation: o, layout: l, weight: newWeight, children: c)
        }
    }
}
