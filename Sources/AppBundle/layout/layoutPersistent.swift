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

/// Layout = `render` (pure geometry from a snapshot of the tiling tree) + `applyRender`. The
/// snapshot is taken fresh each time from the one tree; nothing is cached, so nothing can go stale
/// (a published "generation" used to be kept in sync with the live tree by dirty flags).
extension Workspace {
    /// Render (pure — see `render`), then apply: the only place tile frames are written
    @MainActor
    func layoutWorkspace(skipFloating: Bool = false) async throws {
        if isEffectivelyEmpty { return }
        let windows = rootTilingContainer.allLeafWindowsRecursive
        for window in windows { window.confirmLearnedCap() }
        let spine = currentTilingSpine()
        if windows.contains(where: { $0.learnedMaxSize != nil }) {
            for tile in render(self, spine: spine, ignoringCaps: true).tiles {
                Window.get(byId: tile.windowId)?.reprobeLearnedCapIfSlotChanged(uncappedSlot: tile.physical)
            }
        }
        applyRender(render(self, spine: spine))
        // Mouse-drag hot path skips floating — only tiles need to reflow each frame.
        if !skipFloating {
            try await layoutFloatingChildren(context: LayoutContext(self))
        }
    }

    @MainActor
    private func layoutFloatingChildren(context: LayoutContext) async throws {
        for window in floatingWindows {
            window.applyFrameIntent()
            // Keep belief when set (resize/center on float). Clearing it made
            // focus-follows-mouse miss the float and hit the tile underneath, then
            // nativeFocus raised the tile over the float. Refresh from live if missing.
            if window.knownFrame == nil,
               let live = WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
            {
                window.frame.adopt(live)
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
func assignContainerRects(_ container: TilingContainer) -> (physical: Rect?, virtual: Rect?) {
    var physical: Rect? = nil
    var virtual: Rect? = nil
    for child in container.children {
        let childRects: (physical: Rect?, virtual: Rect?) = switch child.tilingTreeNodeCasesOrDie() {
            case .window(let window): (window.desiredRect, window.lastAppliedLayoutVirtualRect)
            case .tilingContainer(let nested): assignContainerRects(nested)
        }
        physical = physical.union(childRects.physical)
        virtual = virtual.union(childRects.virtual)
    }
    container.desiredRect = physical
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

/// A learned max size (see `Window.frameAnswered`) is dropped once the window is seen LARGER than
/// it — it was mis-learned, or the app's constraint changed.
@MainActor
func unlearnMaxSizeIfExceeded(_ window: Window) {
    let tol: CGFloat = 24
    guard let learned = window.learnedMaxSize, let known = window.knownFrame else { return }
    if (learned.width.isFinite && known.width > learned.width + tol)
        || (learned.height.isFinite && known.height > learned.height + tol)
    {
        window.learnedMaxSize = nil
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
    // Weights are proportions of any scale (no longer pixel spans), so a sum below 1 is normal:
    // only a zero sum needs a fallback (`max(sum, 1)` left a 1.2/0.8 split's stack 20% empty)
    let primaryTotal = masterWeight + stackPaneWeight
    let masterShare: CGFloat = primaryTotal > 0 ? masterWeight / primaryTotal : 0.5
    let primarySpan = orientation == .h ? rect.width : rect.height
    let gap = max(innerGap, 0)
    let usable = max(primarySpan - gap, 0)
    let masterSpan = usable * masterShare
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
    let stackWeightTotal = stackWeightSum > 0 ? stackWeightSum : CGFloat(stackWeights.count)
    let stackGapTotal = gap * CGFloat(max(stackWeights.count - 1, 0))
    let stackUsable = max(stackPrimary - stackGapTotal, 0)
    var cursor = stackRect.topLeftCorner
    for (i, w) in stackWeights.enumerated() {
        let childSpan = stackUsable * ((stackWeightSum > 0 ? w : 1) / stackWeightTotal)
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

/// Smallest span a tile is laid out with (unless the container is too small for all of them)
let minTileSpan: CGFloat = 50

/// Pure: raise every span below `floor` to `floor`, taking the difference proportionally from the
/// spans above it; the total is preserved.
func flooredTileSpans(_ spans: [CGFloat], span: CGFloat, floor: CGFloat) -> [CGFloat] {
    guard floor > 0, spans.contains(where: { $0 < floor }) else { return spans }
    let lowCount = CGFloat(spans.count(where: { $0 < floor }))
    let needed = floor * lowCount - spans.filter { $0 < floor }.reduce(0, +)
    let donors = spans.filter { $0 >= floor }
    let donorExcess = donors.reduce(0) { $0 + ($1 - floor) }
    guard donorExcess > 0 else { return Array(repeating: span / CGFloat(spans.count), count: spans.count) }
    let take = min(needed, donorExcess)
    return spans.map { s in
        s < floor ? floor : s - take * (s - floor) / donorExcess
    }
}
