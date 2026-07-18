import AppKit

extension RgbaColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor { nsColor.cgColor }
}

/// One transparent, click-through overlay window that sits above every normal window and hosts one
/// border layer per managed window. We do NOT try to interleave per-window border windows in the
/// global stack (impossible: our overlays are AppKit windows and AppKit keeps them grouped, so
/// SLSOrderWindow can't slot them among other apps' windows). Instead a single always-on-top overlay
/// draws all borders, and each border is masked to the part of its window that isn't covered by a
/// window stacked above it - which reproduces exactly what you'd see if the border were glued to the
/// window, without any stack-ordering fight
final class WindowBordersOverlay: NSPanelHud {
    let root = CALayer()
    /// Last screen union applied - skip setFrame when monitors haven't moved
    private var lastUnion = CGRect.null

    override init() {
        super.init()
        hasShadow = false
        ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer = root
        contentView = view
    }

    /// Cover the union of all screens so borders on any monitor land in the overlay
    func coverAllScreens() {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull, union != lastUnion else { return }
        lastUnion = union
        setFrame(union, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: union.size)
        CATransaction.commit()
    }
}

/// One managed window's border: a stroked rounded rect plus a mask that hides the parts covered by
/// windows stacked above it. Geometry and style writes are skipped when nothing changed so a
/// full/dirty redraw is cheap when only a subset of borders moved.
@MainActor
private final class BorderEntry {
    let shape = CAShapeLayer()
    let mask = CAShapeLayer()
    var color: RgbaColor = RgbaColor(r: 0, g: 0, b: 0) {
        didSet {
            if color != oldValue { strokeColor = color.cgColor }
        }
    }
    /// Cached so redraws don't re-allocate an NSColor/CGColor every frame
    private(set) var strokeColor: CGColor = RgbaColor(r: 0, g: 0, b: 0).cgColor
    var width = 0
    var radius = 0
    var rect: Rect // live top-left-global frame of the target window

    /// Last values applied to the layer - used to skip path/frame writes. Includes overlay origin so
    /// a multi-monitor reconfig (coverAllScreens moves the overlay) still forces a rewrite even when
    /// the window's global rect is unchanged
    private var appliedRect: Rect?
    private var appliedWidth = -1
    private var appliedRadius = -1
    private var appliedOriginX: CGFloat?
    private var appliedOriginY: CGFloat?
    private var appliedStroke: CGColor?
    private var appliedZ: CGFloat = -1
    private var hadOccluders = false

    init(rect: Rect) {
        self.rect = rect
        shape.fillColor = NSColor.clear.cgColor
        shape.lineJoin = .round
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        strokeColor = color.cgColor
    }

    /// The window rect outset by the border width - the area the border actually paints
    var region: Rect { WindowBordersMath.region(rect: rect, width: width) }

    /// Apply stroke geometry/style. Returns the panel frame in overlay coords (always current).
    @discardableResult
    func applyStroke(originX: CGFloat, originY: CGFloat, zPosition: CGFloat) -> CGRect {
        let w = CGFloat(width)
        let panel = layerRect(rect, originX, originY).insetBy(dx: -w, dy: -w)
        let geometryChanged = appliedRect != rect || appliedWidth != width || appliedRadius != radius
            || appliedOriginX != originX || appliedOriginY != originY
        if geometryChanged {
            appliedRect = rect
            appliedWidth = width
            appliedRadius = radius
            appliedOriginX = originX
            appliedOriginY = originY
            shape.frame = panel
            let strokeRect = CGRect(x: w / 2, y: w / 2, width: panel.width - w, height: panel.height - w)
            let r = CGFloat(radius) + w / 2
            shape.path = CGPath(roundedRect: strokeRect, cornerWidth: r, cornerHeight: r, transform: nil)
            shape.lineWidth = w
        }
        if appliedStroke !== strokeColor {
            appliedStroke = strokeColor
            shape.strokeColor = strokeColor
        }
        if appliedZ != zPosition {
            appliedZ = zPosition
            shape.zPosition = zPosition
        }
        return panel
    }

    func applyMask(panel: CGRect, occluders: [Rect], originX: CGFloat, originY: CGFloat) {
        if occluders.isEmpty {
            if hadOccluders {
                shape.mask = nil
                mask.path = nil
                hadOccluders = false
            }
            return
        }
        hadOccluders = true
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: panel.size))
        for occ in occluders {
            let local = layerRect(occ, originX, originY)
            path.addRect(CGRect(x: local.minX - panel.minX, y: local.minY - panel.minY,
                                width: local.width, height: local.height))
        }
        mask.frame = CGRect(origin: .zero, size: panel.size)
        mask.path = path // even-odd fill -> full panel minus the covered rects
        shape.mask = mask
    }
}

/// WindowServer move/resize callback (runs on the thread that registered it - the main thread).
/// `data` points to the moved window's CGWindowID. Handing it straight to the manager is how border
/// masks track a live drag at the display's refresh rate instead of waiting for AeroSpace's refresh
private let windowBordersEventProc: SkyLight.NotifyProc = { _, data, _, _ in
    guard let data else { return }
    let windowId = data.load(as: UInt32.self)
    if Thread.isMainThread {
        MainActor.assumeIsolated { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    } else {
        DispatchQueue.main.async { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    }
}

@MainActor
final class WindowBordersManager {
    static let shared = WindowBordersManager()
    private let overlay = WindowBordersOverlay()
    private var entries: [UInt32: BorderEntry] = [:]
    /// All on-screen normal windows (excluding our overlay), front-to-back. Used to compute which
    /// windows cover a given border. Rebuilt on each full refresh; a drag only updates the moved rect
    private var stack: [(id: UInt32, rect: Rect)] = []
    /// O(1) id -> stack index. Kept in lockstep with `stack` so move events never scan the array
    private var stackIndex: [UInt32: Int] = [:]
    /// The focused window. Treated as the frontmost window for border purposes: its border is never
    /// masked by another managed window and draws on top, and inactive borders are always clipped
    /// under it. Tiling rarely restacks tiles, so the raw on-screen stack can't be trusted to put the
    /// focused window above a neighbour that overflowed onto it
    private var activeId: UInt32?
    private var observingWindowServer = false

    // MARK: Coalesced dirty redraw (performance)

    /// Border ids that need stroke and/or mask recompute. Full redraws go through refresh() only
    private var dirtyIds: Set<UInt32> = []
    private var redrawScheduled = false
    /// Flushes dirty borders once per run-loop turn (BeforeWaiting), so a burst of WindowServer
    /// move events becomes one CATransaction - without the extra frame of latency that
    /// `DispatchQueue.main.async` would add
    private var coalesceObserver: CFRunLoopObserver?

    private init() {}

    /// Full rebuild: driven from AeroSpace's refresh loop, so it runs on every focus / move / resize /
    /// layout / workspace change. Establishes which windows are bordered, their colors, and the stack
    func refresh() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled else {
            teardownAll()
            return
        }
        if !observingWindowServer {
            observingWindowServer = true
            SkyLight.registerWindowEvents(windowBordersEventProc)
        }
        overlay.coverAllScreens()
        overlay.orderFrontRegardless()

        activeId = focus.windowOrNil?.windowId
        var seen = Set<UInt32>(minimumCapacity: entries.count)
        for workspace in Workspace.allUnsorted where workspace.isVisible {
            for window in workspace.allLeafWindowsRecursive {
                guard let rect = SkyLight.overlayBounds(window.windowId) ?? window.lastAppliedLayoutPhysicalRect else { continue }
                seen.insert(window.windowId)
                let entry = entries[window.windowId] ?? makeEntry(window.windowId, rect: rect)
                entry.rect = rect
                entry.color = window.windowId == activeId ? cfg.activeColor : cfg.inactiveColor
                entry.width = cfg.width
                entry.radius = cfg.cornerRadius(forAppId: window.app.rawAppBundleId)
            }
        }
        for (id, entry) in entries where !seen.contains(id) {
            entry.shape.removeFromSuperlayer()
            entries.removeValue(forKey: id)
        }

        rebuildStack(onScreenStack())
        // Config / membership / stack order may have changed - full recompute once, immediately
        // (refresh is already session-batched; no need to coalesce further)
        flushAll()
    }

    /// A window moved/resized (WindowServer event). This callback fires for EVERY window on the
    /// system. Cost model (must stay sub-millisecond on modest hardware):
    /// 1. O(1) rect update via stackIndex
    /// 2. Early-out if the move can't affect any border (unrelated animation)
    /// 3. Mark only the borders whose stroke/mask can change
    /// 4. Coalesce all events in this run-loop turn into ONE Core Animation transaction
    func handleWindowMoved(windowId: UInt32) {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }
        guard let rect = SkyLight.overlayBounds(windowId) else { return }

        let oldRect: Rect?
        if let i = stackIndex[windowId] {
            oldRect = stack[i].rect
            // Skip no-op events (WindowServer sometimes re-notifies the same frame)
            if oldRect == rect {
                entries[windowId]?.rect = rect
                return
            }
            stack[i].rect = rect
        } else {
            oldRect = nil
            stackIndex[windowId] = stack.count
            stack.append((windowId, rect))
        }
        entries[windowId]?.rect = rect

        let moverIsBordered = entries[windowId] != nil
        // Early-out without allocating: walk entries in place. Unrelated animations hit this path
        // on every WS event, so it must stay allocation-free
        if !moverIsBordered {
            let hitsNew = overlapsAnyBorderInPlace(rect)
            let hitsOld = oldRect.map(overlapsAnyBorderInPlace) ?? false
            guard hitsNew || hitsOld else { return }
        }

        scheduleRedraw(dirty: WindowBordersMath.affectedBorderIds(
            mover: windowId,
            moverIsBordered: moverIsBordered,
            borderRegions: borderRegionsSnapshot(),
            oldRect: oldRect,
            newRect: rect,
        ))
    }

    // MARK: Dirty set + coalesce

    /// Allocation-free overlap test against live entries (hot path for unrelated window animations)
    private func overlapsAnyBorderInPlace(_ rect: Rect) -> Bool {
        for (_, entry) in entries {
            if WindowBordersMath.rectsIntersect(entry.region, rect) { return true }
        }
        return false
    }

    /// Snapshot of painted regions for pure-math dirty set computation
    private func borderRegionsSnapshot() -> [(id: UInt32, region: Rect)] {
        var regions: [(id: UInt32, region: Rect)] = []
        regions.reserveCapacity(entries.count)
        for (id, entry) in entries {
            regions.append((id, entry.region))
        }
        return regions
    }

    private func scheduleRedraw(dirty: Set<UInt32>) {
        dirtyIds.formUnion(dirty)
        guard !redrawScheduled else { return }
        redrawScheduled = true
        // Coalesce every WindowServer event that arrives before the run loop would sleep into a
        // single CATransaction. Zero added frames vs immediate paint; one paint per turn under load
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false, // one-shot
            0,
        ) { [self] _, _ in
            MainActor.assumeIsolated {
                self.redrawScheduled = false
                self.coalesceObserver = nil
                let dirty = self.dirtyIds
                self.dirtyIds.removeAll(keepingCapacity: true)
                self.flushDirty(dirty)
            }
        }
        coalesceObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func flushAll() {
        flush { paint in
            for (id, entry) in entries {
                paint(id, entry)
            }
        }
    }

    private func flushDirty(_ dirty: Set<UInt32>) {
        flush { paint in
            for id in dirty {
                guard let entry = entries[id] else { continue }
                paint(id, entry)
            }
        }
    }

    private func flush(_ body: (_ paint: (UInt32, BorderEntry) -> Void) -> Void) {
        let originX = overlay.frame.origin.x
        let originY = overlay.frame.origin.y
        let managedIds = Set(entries.keys)
        let activeRect = activeId.flatMap { entries[$0]?.rect }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body { id, entry in
            paint(id: id, entry: entry, originX: originX, originY: originY,
                  managedIds: managedIds, activeRect: activeRect)
        }
        CATransaction.commit()
    }

    private func paint(
        id: UInt32,
        entry: BorderEntry,
        originX: CGFloat,
        originY: CGFloat,
        managedIds: Set<UInt32>,
        activeRect: Rect?,
    ) {
        let panel = entry.applyStroke(originX: originX, originY: originY, zPosition: id == activeId ? 1 : 0)
        let occluders = WindowBordersMath.occluders(
            id: id,
            region: entry.region,
            isActive: id == activeId,
            activeId: activeId,
            activeRect: activeRect,
            stack: stack,
            stackIndex: stackIndex[id],
            managedIds: managedIds,
        )
        entry.applyMask(panel: panel, occluders: occluders, originX: originX, originY: originY)
    }

    private func makeEntry(_ id: UInt32, rect: Rect) -> BorderEntry {
        let entry = BorderEntry(rect: rect)
        overlay.root.addSublayer(entry.shape)
        entries[id] = entry
        return entry
    }

    private func teardownAll() {
        if let observer = coalesceObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            coalesceObserver = nil
        }
        redrawScheduled = false
        dirtyIds.removeAll()
        for (_, entry) in entries { entry.shape.removeFromSuperlayer() }
        entries.removeAll()
        stack.removeAll()
        stackIndex.removeAll()
        overlay.orderOut(nil)
    }

    private func rebuildStack(_ newStack: [(id: UInt32, rect: Rect)]) {
        stack = newStack
        stackIndex.removeAll(keepingCapacity: true)
        stackIndex.reserveCapacity(newStack.count)
        for (i, item) in newStack.enumerated() {
            stackIndex[item.id] = i
        }
    }

    /// All on-screen normal (layer 0) windows except our own, front-to-back
    private func onScreenStack() -> [(id: UInt32, rect: Rect)] {
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [(UInt32, Rect)] = []
        result.reserveCapacity(arr.count)
        for w in arr {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != myPid,
                  let wid = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let rect = Rect(topLeftX: (b["X"] as? CGFloat) ?? 0, topLeftY: (b["Y"] as? CGFloat) ?? 0,
                            width: (b["Width"] as? CGFloat) ?? 0, height: (b["Height"] as? CGFloat) ?? 0)
            result.append((UInt32(wid), rect))
        }
        return result
    }
}

/// A top-left-global Rect converted to overlay-layer coordinates (bottom-left, overlay-relative)
@MainActor
private func layerRect(_ r: Rect, _ originX: CGFloat, _ originY: CGFloat) -> CGRect {
    let ak = r.toAppKitFrame()
    return CGRect(x: ak.origin.x - originX, y: ak.origin.y - originY, width: ak.width, height: ak.height)
}

extension Rect {
    /// Convert an AeroSpace Rect (top-left origin, y-down) to an AppKit frame (bottom-left, y-up).
    /// AeroSpace Rects live in the unified main-screen-relative space, so the flip uses mainMonitor.height
    @MainActor func toAppKitFrame() -> NSRect {
        NSRect(
            x: topLeftX,
            y: mainMonitor.height - (topLeftY + height),
            width: width,
            height: height,
        )
    }
}
