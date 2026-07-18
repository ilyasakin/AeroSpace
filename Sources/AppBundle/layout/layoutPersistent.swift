import AppKit
import Common

/// Tiling layout driven by the immutable persistent spine (#1215 cutover).
///
/// Structure and weights for geometry come only from `PersistentTilingNode`. Windows are
/// resolved by id for AX writes. There is no spine/`liveChildren[i]` index pairing for
/// geometry or weight distribution. Accordion MRU consults live focus metadata (most-recent
/// window id) only to pick which spine sibling is "front."
///
/// Structural mutations that go through `commitTilingTransform` publish a generation.
/// Dual-link bind/unbind/`setWeight` invalidate it. Layout: if gen present trust it; if nil capture.

extension Workspace {
    /// Last tiling spine used for layout / commits (updated each layout or commit).
    /// nonisolated(unsafe): dual-link bind/unbind may invalidate off the typed MainActor boundary
    /// while still running on the main thread under AeroSpace's session model.
    private nonisolated(unsafe) static var _tilingSpineByName: [String: PersistentTilingNode] = [:]

    /// When true, `setWeight` must not invalidate the generation (used while syncing spine → live
    /// after layout so the published gen is not wiped mid-walk).
    nonisolated(unsafe) static var suppressTilingGenerationInvalidation = false

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

    /// Dual-link structure/weight mutation: clear published spine so next layout recaptures live.
    func invalidateTilingStructureGeneration() {
        if unsafe Self.suppressTilingGenerationInvalidation { return }
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

        // Dirty-flag: trust published gen; capture only when nil
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
        // Sync live dual-link weights without invalidating, then publish generation once
        unsafe Self.suppressTilingGenerationInvalidation = true
        applyWeightsFromSpine(laidOut, live: rootTilingContainer, parentOrientation: nil)
        unsafe Self.suppressTilingGenerationInvalidation = false
        tilingStructureGeneration = laidOut

        try await layoutFloatingChildren(context: context)
    }

    @MainActor
    private func layoutFloatingChildren(context: LayoutContext) async throws {
        for window in floatingWindows {
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            try await window.layoutFloatingWindow(context)
        }
    }
}

/// Apply spine weights onto live dual-link nodes. Windows match by id; nested containers match by
/// descendant window-id set (structure identity), not geometry index-pairing.
@MainActor
private func applyWeightsFromSpine(
    _ node: PersistentTilingNode,
    live: TreeNode?,
    parentOrientation: Orientation?,
) {
    switch node {
        case .window(let id, let weight):
            guard let parentOrientation,
                  let window = Window.get(byId: id),
                  window.parent is TilingContainer
            else { return }
            window.setWeight(parentOrientation, weight)
        case .container(let orientation, _, let weight, let children):
            let liveContainer: TilingContainer? = {
                if let c = live as? TilingContainer { return c }
                // Resolve nested container by matching leaf window set
                guard let live else { return nil }
                if let c = live as? TilingContainer { return c }
                return nil
            }()
            if let parentOrientation, let liveContainer, liveContainer.parent is TilingContainer {
                liveContainer.setWeight(parentOrientation, weight)
            }
            guard let liveContainer else {
                // Still apply window leaves by id
                for child in children {
                    applyWeightsFromSpine(child, live: nil, parentOrientation: orientation)
                }
                return
            }
            let liveChildren = liveContainer.children
            for child in children {
                switch child {
                    case .window(let id, _):
                        let liveChild = Window.get(byId: id) ?? liveChildren.first { ($0 as? Window)?.windowId == id }
                        applyWeightsFromSpine(child, live: liveChild, parentOrientation: orientation)
                    case .container:
                        let childIds = Set(child.windowIds)
                        let liveChild = liveChildren.first { node in
                            guard let c = node as? TilingContainer else { return false }
                            return Set(c.allLeafWindowsRecursive.map(\.windowId)) == childIds
                        }
                        applyWeightsFromSpine(child, live: liveChild, parentOrientation: orientation)
                }
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
                case .master:
                    return try await layoutPersistentMaster(
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

/// Pure geometry for master layout: master (index 0) + stack rects for the rest.
///
/// Primary split is **master weight vs average stack weight** (stack treated as one pane), so equal
/// weights always yield ~50/50 regardless of stack count. Stack children then share the secondary
/// pane by their own weights (tiles-style). `innerGap` applies only to physical layout; pass 0 for
/// virtual rects (gaps-as-zero contract, same as tiles).
func masterLayoutChildRects(
    orientation: Orientation,
    childWeights: [CGFloat],
    rect: Rect,
    innerGap: CGFloat,
) -> [Rect] {
    guard !childWeights.isEmpty else { return [] }
    if childWeights.count == 1 {
        return [rect]
    }
    let masterWeight = max(childWeights[0], 0)
    let stackWeights = Array(childWeights.dropFirst())
    let stackWeightSum = stackWeights.reduce(CGFloat(0), +)
    // Stack pane weight = average of stack children (not sum). Equal weights → 50/50 forever.
    let stackPaneWeight = max(stackWeightSum / CGFloat(stackWeights.count), 0)
    let primaryTotal = max(masterWeight + stackPaneWeight, 1)
    let primarySpan = orientation == .h ? rect.width : rect.height
    let gap = max(innerGap, 0)
    let usable = max(primarySpan - gap, 0)
    let masterSpan = usable * (masterWeight / primaryTotal)
    let stackSpan = usable - masterSpan

    let masterRect: Rect
    let stackRect: Rect
    switch orientation {
        case .h:
            masterRect = Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: masterSpan, height: rect.height)
            stackRect = Rect(
                topLeftX: rect.topLeftX + masterSpan + gap,
                topLeftY: rect.topLeftY,
                width: stackSpan,
                height: rect.height,
            )
        case .v:
            masterRect = Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width, height: masterSpan)
            stackRect = Rect(
                topLeftX: rect.topLeftX,
                topLeftY: rect.topLeftY + masterSpan + gap,
                width: rect.width,
                height: stackSpan,
            )
    }

    var result: [Rect] = [masterRect]
    // Stack along the opposite orientation using proportional weights
    let stackOrientation = orientation.opposite
    let stackPrimary = stackOrientation == .h ? stackRect.width : stackRect.height
    let stackWeightTotal = max(stackWeightSum, 1)
    let stackGapTotal = gap * CGFloat(max(stackWeights.count - 1, 0))
    let stackUsable = max(stackPrimary - stackGapTotal, 0)
    var cursor = stackRect.topLeftCorner
    for (i, w) in stackWeights.enumerated() {
        let childSpan = stackUsable * (w / stackWeightTotal)
        let childRect: Rect = switch stackOrientation {
            case .h: Rect(topLeftX: cursor.x, topLeftY: cursor.y, width: childSpan, height: stackRect.height)
            case .v: Rect(topLeftX: cursor.x, topLeftY: cursor.y, width: stackRect.width, height: childSpan)
        }
        result.append(childRect)
        if i < stackWeights.count - 1 {
            cursor = stackOrientation == .h
                ? cursor.addingXOffset(childSpan + gap)
                : cursor.addingYOffset(childSpan + gap)
        }
    }
    return result
}

@MainActor
private func layoutPersistentMaster(
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
    if children.count == 1 {
        let laidOut = try await layoutPersistentNode(
            children[0],
            point: point,
            width: width,
            height: height,
            virtual: virtual,
            context: context,
            mruWindowId: mruWindowId,
        )
        return .container(orientation: orientation, layout: layout, weight: weight, children: [laidOut])
    }

    let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
    let weights = children.map(\.weight)
    let physical = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
    let rects = masterLayoutChildRects(
        orientation: orientation,
        childWeights: weights,
        rect: physical,
        innerGap: rawGap,
    )
    // Virtual = geometry as if gaps were zero (matches tiles contract / mouse-resize baseline)
    let virtualRects = masterLayoutChildRects(
        orientation: orientation,
        childWeights: weights,
        rect: virtual,
        innerGap: 0,
    )

    var newChildren: [PersistentTilingNode] = []
    newChildren.reserveCapacity(children.count)
    for (i, child) in children.enumerated() {
        let r = rects[i]
        let v = virtualRects[i]
        let laidOut = try await layoutPersistentNode(
            child,
            point: r.topLeftCorner,
            width: r.width,
            height: r.height,
            virtual: v,
            context: context,
            mruWindowId: mruWindowId,
        )
        newChildren.append(laidOut)
    }
    return .container(orientation: orientation, layout: layout, weight: weight, children: newChildren)
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
        let laidOut: PersistentTilingNode = switch orientation {
            case .h:
                try await layoutPersistentNode(
                    child,
                    point: point + CGPoint(x: lPadding, y: 0),
                    width: width - rPadding - lPadding,
                    height: height,
                    virtual: virtual,
                    context: context,
                    mruWindowId: mruWindowId,
                )
            case .v:
                try await layoutPersistentNode(
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


