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
    ///
    /// Prefer `withSuppressedGenerationInvalidation` over touching this directly: it is a plain
    /// boolean, so an early return / throw / cancellation between set and reset leaves it stuck
    /// `true` — which silently disables invalidation for the WHOLE PROCESS, turning every later
    /// dual-link mutation into a stale-spine desync. `layoutWorkspace` is `async throws`, so that
    /// was reachable in practice.
    nonisolated(unsafe) static var suppressTilingGenerationInvalidation = false

    /// Run `body` with generation invalidation suppressed, restoring the previous value even on
    /// throw/cancellation. Nesting-safe (saves and restores rather than forcing `false`).
    static func withSuppressedGenerationInvalidation<T>(_ body: () throws -> T) rethrows -> T {
        let previous = unsafe suppressTilingGenerationInvalidation
        unsafe suppressTilingGenerationInvalidation = true
        defer { unsafe suppressTilingGenerationInvalidation = previous }
        return try body()
    }

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
    func layoutWorkspace(skipFloating: Bool = false) async throws {
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
        Self.withSuppressedGenerationInvalidation {
            applyWeightsFromSpine(laidOut, live: rootTilingContainer, parentOrientation: nil)
        }
        tilingStructureGeneration = laidOut
        // Layout publishes a generation on EVERY pass, and the walk above contains `await`s — so a
        // window that dies mid-walk leaves `laidOut` describing a tree that no longer exists. This
        // was the hottest unverified publishing path; on violation the guard self-heals by dropping
        // the generation so the next layout recaptures from live. Weights are ignored by the
        // comparison, so the normalized spans in `laidOut` are preserved.
        SpineInvariant.verify(self, context: "layoutWorkspace")
        // Layout assigns rects to windows only, so nested containers had none — making them dead
        // zones for anything that hit-tests the tree (drag-to-swap over a nested split found no
        // target; directional focus fallbacks misrouted). Derive them once here, bottom-up, so
        // every reader sees container geometry instead of each call site working around its
        // absence.
        assignContainerRects(rootTilingContainer)

        // Mouse-drag hot path skips floating — only tiles need to reflow each frame.
        if !skipFloating {
            try await layoutFloatingChildren(context: context)
        }
    }

    @MainActor
    private func layoutFloatingChildren(context: LayoutContext) async throws {
        for window in floatingWindows {
            // Keep lastApplied when set (resize/center on float). Clearing it made
            // focus-follows-mouse miss the float and hit the tile underneath, then
            // nativeFocus raised the tile over the float. Refresh from live if missing.
            if window.lastAppliedLayoutPhysicalRect == nil {
                window.lastAppliedLayoutPhysicalRect =
                    WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
            }
            try await window.layoutFloatingWindow(context)
        }
    }
}

/// Give every tiling container the bounding rect of its laid-out descendants (bottom-up).
///
/// Layout writes rects only on windows and the workspace. Containers are rebuilt by every
/// materialize, so they never carried geometry — every consumer that needed a container's bounds
/// (mouse drag-to-swap targeting, directional focus fallbacks) had to derive it or silently treat
/// the container as a dead zone. Returns the union so parents can accumulate.
@MainActor
@discardableResult
private func assignContainerRects(_ container: TilingContainer) -> (physical: Rect?, virtual: Rect?) {
    var physical: Rect? = nil
    var virtual: Rect? = nil
    for child in container.children {
        let childRects: (physical: Rect?, virtual: Rect?) = switch child.tilingTreeNodeCasesOrDie() {
            case .window(let window): (window.lastAppliedLayoutPhysicalRect, window.lastAppliedLayoutVirtualRect)
            case .tilingContainer(let nested): assignContainerRects(nested)
        }
        physical = physical.union(childRects.physical)
        virtual = virtual.union(childRects.virtual)
    }
    container.lastAppliedLayoutPhysicalRect = physical
    container.lastAppliedLayoutVirtualRect = virtual
    return (physical, virtual)
}

extension Rect? {
    /// Bounding box of two optional rects (nil is identity).
    fileprivate func union(_ other: Rect?) -> Rect? {
        guard let other else { return self }
        guard let self else { return other }
        let minX = min(self.topLeftX, other.topLeftX)
        let minY = min(self.topLeftY, other.topLeftY)
        let maxX = max(self.topLeftX + self.width, other.topLeftX + other.width)
        let maxY = max(self.topLeftY + self.height, other.topLeftY + other.height)
        return Rect(topLeftX: minX, topLeftY: minY, width: maxX - minX, height: maxY - minY)
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
                  let parent = window.parent as? TilingContainer,
                  // setWeight fatally die()s for accordion parents and for orientation mismatches
                  // (live tree can drift from the spine mid-transition) — guard both instead of
                  // crashing the WM (repro: `layout accordion` killed the app on next layout tick)
                  parent.layout == .tiles || parent.layout == .master,
                  parent.orientation == parentOrientation
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
            // Same guard as the window case above — a CONTAINER child of an accordion (produced by
            // `join-with`/`split`/`toggle-group` inside an accordion, which normalization keeps
            // because single-child accordions are exempt from flattening) would otherwise reach
            // setWeight's die() and kill the WM on the next layout tick.
            if let parentOrientation, let liveContainer,
               let parent = liveContainer.parent as? TilingContainer,
               parent.layout == .tiles || parent.layout == .master,
               parent.orientation == parentOrientation
            {
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

/// Discover a window's hard max size by observing it refuse to grow. `requested` is the frame we
/// asked for last layout; if the live frame settled meaningfully smaller in a dimension, that's a
/// cap. Confirmed across two consecutive observations (candidate → learned) so a transient
/// launch/animation size is never latched. Cheap SkyLight read; no AX round-trip.
@MainActor
private func learnMaxSizeIfClamped(_ window: Window, requested: Rect) {
    let tol: CGFloat = 24
    // Never learn during a mouse manipulation: MouseResizeDriver relayouts every vsync and
    // growing SIBLINGS lag their AX apply by a frame or two — two lagged observations latched a
    // permanent bogus cap on a perfectly resizable window.
    if currentlyManipulatedWithMouseWindowId != nil {
        window.maxSizeCandidate = nil
        return
    }
    guard let live = WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: false)
    else { return }
    // Unlearn on contrary evidence: if the window is ever LARGER than its supposed cap, the cap
    // was mis-learned (AX lag, transient state) — drop it. This was the missing unlearn path
    // (previously only a manual `resize` on the exact window cleared it).
    if let learned = window.learnedMaxSize {
        if (learned.width.isFinite && live.width > learned.width + tol)
            || (learned.height.isFinite && live.height > learned.height + tol)
        {
            window.learnedMaxSize = nil
            window.maxSizeCandidate = nil
        }
    }
    // Only a window that ACCEPTED our position can prove a size clamp. A stashed/hidden window
    // (moved to the off-screen corner) differs in position too — learning from it latched bogus
    // caps (VLC "does not sit well in the tile" after a fullscreen round-trip).
    guard abs(live.topLeftX - requested.topLeftX) < tol, abs(live.topLeftY - requested.topLeftY) < tol
    else {
        window.maxSizeCandidate = nil
        return
    }
    let capW: CGFloat = live.width < requested.width - tol ? live.width : .infinity
    let capH: CGFloat = live.height < requested.height - tol ? live.height : .infinity
    guard capW.isFinite || capH.isFinite else {
        // Filled the requested frame in both dimensions — no new clamp. Keep any prior learned cap
        // (it simply doesn't bite in the current slot); just drop the pending candidate.
        window.maxSizeCandidate = nil
        return
    }
    let obs = CGSize(width: capW, height: capH)
    if let cand = window.maxSizeCandidate,
       maxCapsMatch(cand.width, obs.width, tol), maxCapsMatch(cand.height, obs.height, tol)
    {
        window.learnedMaxSize = obs // second matching observation → trust it
    }
    window.maxSizeCandidate = obs
}

/// Two per-dimension caps agree when both are unconstrained (.infinity) or within tolerance.
private func maxCapsMatch(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat) -> Bool {
    if a == .infinity || b == .infinity { return a == b }
    return abs(a - b) < tol
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
            let mouseTarget = window.windowId == currentlyManipulatedWithMouseWindowId
            window.lastAppliedLayoutVirtualRect = virtual
            if window.isFullscreen,
               window == context.workspace.rootTilingContainer.mostRecentWindowRecursive
            {
                window.lastAppliedLayoutPhysicalRect = nil
                window.layoutFullscreen(context)
            } else {
                let prev = window.lastAppliedLayoutPhysicalRect
                // Learn a hard max size: if we asked the window to grow wider/taller last time and
                // it refused, record the clamp so tiles distribution stops over-allocating (the
                // System Settings gap). Off the mouse-resize path (user owns that frame).
                if !mouseTarget, let prev {
                    learnMaxSizeIfClamped(window, requested: prev)
                }
                // Always record layout geometry — borders paint from lastApplied during drag so
                // all tiles share one coherent frame (live WS on the drag target vs layout on
                // siblings made the shared edge thrash left/right).
                window.lastAppliedLayoutPhysicalRect = physicalRect
                window.isFullscreen = false
                // Mouse-resize target: user owns the AX frame; only skip the write.
                if !mouseTarget, prev != physicalRect {
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
    let span = orientation == .h ? width : height
    var point = point
    var virtualPoint = virtual.topLeftCorner
    let lastIndex = children.indices.last
    let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
    var newChildren: [PersistentTilingNode] = []
    newChildren.reserveCapacity(children.count)

    // PROPORTIONAL normalization: each child gets its share of the span.
    //
    // This was additive (`weight + (span - weightSum)/count`), which preserves DIFFERENCES rather
    // than ratios — so any authored ratio decayed on the first layout. `dwindle-split-percent = 70`
    // emitted weights [1.4, 0.6] and became 500.4px/499.6px of a 1000px span: a 50/50 split, i.e.
    // the setting was silently inert. Proportional normalization keeps ratios invariant under any
    // span change, which is what every weight producer (dwindle ratios, master's ratio math,
    // balance-sizes, WEIGHT_AUTO) already assumes.
    //
    // Weights continue to be written back as the resulting spans. Under proportional
    // normalization that is just one valid relative encoding (ratios are unchanged by scale), and
    // it keeps the pixel-denominated commands (`resize --width +50`, `resize-to`, mouse edge
    // resize) working against `getWeight()` exactly as before.
    //
    // Geometry then uses `slotSpans`, which may cap a max-constrained window (System Settings)
    // and give the freed span to its siblings. Cap = learned window max + one gap.
    let rawWeightSum = CGFloat(children.sumOfDouble { Double(max($0.weight, 0)) })
    let adjustedWeights: [CGFloat] = rawWeightSum > 0
        ? children.map { span * max($0.weight, 0) / rawWeightSum }
        : Array(repeating: span / CGFloat(children.count), count: children.count)
    let caps: [CGFloat?] = children.map { child in
        guard case .window(let id, _) = child,
              let maxSize = Window.get(byId: id)?.learnedMaxSize else { return nil }
        let dim = orientation == .h ? maxSize.width : maxSize.height
        return dim.isFinite ? dim + rawGap : nil
    }
    let slotSpans = tileCapsAreActive(caps)
        ? waterfillTileSpans(weights: adjustedWeights, caps: caps, span: span)
        : adjustedWeights

    // When capped windows can't fill the span and there are no growable siblings to absorb the
    // rest (a lone max-constrained window, or all children capped), center the row in the leftover
    // so the gap is symmetric rather than a lopsided trailing gap. No leftover in the normal case.
    let leftover = max(span - slotSpans.reduce(0, +), 0)
    if leftover > 0.5 {
        point = point.addingOffset(orientation, leftover / 2)
        virtualPoint = orientation == .h
            ? virtualPoint.addingXOffset(leftover / 2)
            : virtualPoint.addingYOffset(leftover / 2)
    }

    for (i, child) in children.enumerated() {
        let adjustedWeight = adjustedWeights[i]
        let slotSpan = slotSpans[i]
        let adjustedChild = child.withWeight(adjustedWeight) // persist uncapped weight

        let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
        let childPoint = i == 0 ? point : point.addingOffset(orientation, rawGap / 2)
        let childWidth = orientation == .h ? slotSpan - gap : width
        let childHeight = orientation == .v ? slotSpan - gap : height
        let childVirtual = Rect(
            topLeftX: virtualPoint.x,
            topLeftY: virtualPoint.y,
            width: orientation == .h ? slotSpan : width,
            height: orientation == .v ? slotSpan : height,
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
            ? virtualPoint.addingXOffset(slotSpan)
            : virtualPoint.addingYOffset(slotSpan)
        point = orientation == .h
            ? point.addingXOffset(slotSpan)
            : point.addingYOffset(slotSpan)
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


