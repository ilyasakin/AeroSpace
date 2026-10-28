import AppKit
import Common

/// Where one tiled window goes: its frame with gaps (`physical`, what gets written) and as if inner
/// gaps were zero (`virtual`, the mouse-resize and hit-testing baseline)
struct TileRender: Equatable {
    let windowId: UInt32
    let physical: Rect
    let virtual: Rect
}

/// What one workspace should look like — computed, never applied here.
///
/// `render` is a pure function of the model (tiling structure, weights, learned size caps, focus
/// order, config) and the workspace's rect: no frame writes, no reads of macOS, no mutation, no
/// suspension points. It used to be interleaved with its effects: every tile's frame was written
/// in the middle of the walk (so a window could die half-way through a layout), intent was
/// recorded as it went, and the computed pixel spans were written back into the tree as its new
/// weights. Applying a render is the reconciler's job (`applyRender`).
struct WorkspaceRender: Equatable {
    /// The tiling area with gaps (what tiles are written into) and without
    let physical: Rect
    let virtual: Rect
    /// In tree order
    let tiles: [TileRender]
}

@MainActor
func render(_ workspace: Workspace, spine: PersistentTilingNode, ignoringCaps: Bool = false) -> WorkspaceRender {
    let rect = workspace.tilingRect
    // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
    // window on the upper monitor to take full width. rect.height - 1 resolves this problem
    // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
    let physical = Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width, height: rect.height - 1)
    var renderer = TilingRenderer(
        gaps: workspace.resolvedGaps,
        mruWindowId: workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId,
        accordionMode: config.accordionMode,
        accordionPadding: CGFloat(config.accordionPadding),
        maxSize: { ignoringCaps ? nil : Window.get(byId: $0)?.learnedMaxSize },
    )
    renderer.node(spine, physical: physical, virtual: rect)
    return WorkspaceRender(physical: physical, virtual: rect, tiles: renderer.tiles)
}

/// The tiles / accordion / master geometry. Everything it needs is passed in; it only computes.
private struct TilingRenderer {
    let gaps: ResolvedGaps
    let mruWindowId: UInt32?
    let accordionMode: AccordionMode
    let accordionPadding: CGFloat
    let maxSize: (UInt32) -> CGSize?
    var tiles: [TileRender] = []

    mutating func node(_ node: PersistentTilingNode, physical: Rect, virtual: Rect) {
        switch node {
            case .window(let id, _):
                tiles.append(TileRender(windowId: id, physical: physical, virtual: virtual))
            case .container(let orientation, let layout, _, let children, _):
                guard !children.isEmpty else { return }
                switch layout {
                    case .tiles: self.tiles(orientation, children, physical: physical, virtual: virtual)
                    case .accordion: accordion(orientation, children, physical: physical, virtual: virtual)
                    case .master: master(orientation, children, physical: physical, virtual: virtual)
                }
        }
    }

    private mutating func master(_ orientation: Orientation, _ children: [PersistentTilingNode], physical: Rect, virtual: Rect) {
        if children.count == 1 {
            node(children[0], physical: physical, virtual: virtual)
            return
        }
        let weights = children.map(\.weight)
        let rects = masterLayoutChildRects(orientation: orientation, childWeights: weights, rect: physical, innerGap: gaps.inner.get(orientation).toDouble())
        // Virtual = geometry as if gaps were zero (matches tiles contract / mouse-resize baseline)
        let virtualRects = masterLayoutChildRects(orientation: orientation, childWeights: weights, rect: virtual, innerGap: 0)
        for (i, child) in children.enumerated() {
            node(child, physical: rects[i], virtual: virtualRects[i])
        }
    }

    private mutating func tiles(_ orientation: Orientation, _ children: [PersistentTilingNode], physical: Rect, virtual: Rect) {
        let width = physical.width
        let height = physical.height
        let span = orientation == .h ? width : height
        var point = physical.topLeftCorner
        var virtualPoint = virtual.topLeftCorner
        let lastIndex = children.indices.last
        let rawGap = gaps.inner.get(orientation).toDouble()

        // PROPORTIONAL: each child gets its share of the span. (It was additive, which preserves
        // differences rather than ratios — an authored 70/30 split decayed to 50/50 on first layout.)
        let rawWeightSum = CGFloat(children.sumOfDouble { Double(max($0.weight, 0)) })
        let proportional: [CGFloat] = rawWeightSum > 0
            ? children.map { span * max($0.weight, 0) / rawWeightSum }
            : Array(repeating: span / CGFloat(children.count), count: children.count)
        // Degenerate weights (0 / a few px — from old negative-weight resizes, a restored session)
        // must not leave a tile unusable: floor each tile's span (i3's con_fix_percent)
        let flooredSpans = flooredTileSpans(proportional, span: span, floor: min(minTileSpan, span / CGFloat(max(children.count, 1))))
        // A window with a learned max size gets at most that (+ a gap); siblings take the rest
        let caps: [CGFloat?] = children.map { child in
            guard case .window(let id, _) = child, let max = maxSize(id) else { return nil }
            let dim = orientation == .h ? max.width : max.height
            return dim.isFinite ? dim + rawGap : nil
        }
        let slotSpans = tileCapsAreActive(caps)
            ? waterfillTileSpans(weights: flooredSpans, caps: caps, span: span)
            : flooredSpans

        // Capped windows that can't fill the span with no growable sibling: centre the row so the
        // gap is symmetric rather than trailing
        let leftover = max(span - slotSpans.reduce(0, +), 0)
        if leftover > 0.5 {
            point = point.addingOffset(orientation, leftover / 2)
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(leftover / 2) : virtualPoint.addingYOffset(leftover / 2)
        }

        for (i, child) in children.enumerated() {
            let slotSpan = slotSpans[i]
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            let childPoint = i == 0 ? point : point.addingOffset(orientation, rawGap / 2)
            let childPhysical = Rect(
                topLeftX: childPoint.x,
                topLeftY: childPoint.y,
                width: orientation == .h ? slotSpan - gap : width,
                height: orientation == .v ? slotSpan - gap : height,
            )
            let childVirtual = Rect(
                topLeftX: virtualPoint.x,
                topLeftY: virtualPoint.y,
                width: orientation == .h ? slotSpan : width,
                height: orientation == .v ? slotSpan : height,
            )
            node(child, physical: childPhysical, virtual: childVirtual)
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(slotSpan) : virtualPoint.addingYOffset(slotSpan)
            point = orientation == .h ? point.addingXOffset(slotSpan) : point.addingYOffset(slotSpan)
        }
    }

    private mutating func accordion(_ orientation: Orientation, _ children: [PersistentTilingNode], physical: Rect, virtual: Rect) {
        let point = physical.topLeftCorner
        let width = physical.width
        let height = physical.height
        if accordionMode == .i3 {
            // i3 tabbed/stacked: every member fills the container below the title band; the focused
            // one is simply on top (focus raises it)
            let band = min(i3TitleBandHeight(orientation: orientation, childCount: children.count), max(height - 1, 0))
            for child in children {
                node(child, physical: Rect(topLeftX: point.x, topLeftY: point.y + band, width: width, height: height - band), virtual: virtual)
            }
            return
        }
        // The focused member (MRU) is the one shown in full; its neighbours peek out by the padding
        let mruIndex: Int = {
            guard let mruWindowId else { return 0 }
            return children.firstIndex(where: { child in
                switch child {
                    case .window(let id, _): id == mruWindowId
                    case .container: child.windowIds.contains(mruWindowId)
                }
            }) ?? 0
        }()
        let lastIndex = children.indices.last
        for (index, child) in children.enumerated() {
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0: (0, accordionPadding)
                case lastIndex: (accordionPadding, 0)
                case mruIndex - 1: (0, 2 * accordionPadding)
                case mruIndex + 1: (2 * accordionPadding, 0)
                default: (accordionPadding, accordionPadding)
            }
            let childPhysical: Rect = switch orientation {
                case .h: Rect(topLeftX: point.x + lPadding, topLeftY: point.y, width: width - rPadding - lPadding, height: height)
                case .v: Rect(topLeftX: point.x, topLeftY: point.y + lPadding, width: width, height: height - lPadding - rPadding)
            }
            node(child, physical: childPhysical, virtual: virtual)
        }
    }
}
