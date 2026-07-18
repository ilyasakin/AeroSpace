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

    /// Full-screen overlay must stay invisible to AX (focus-follows-mouse); same rationale as StatusBar.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

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
///
/// Pure translation (same size) only moves `host.frame` — no CGPath rebuild (JankyBorders move parity
/// within the overlay model).
///
/// All paint layers (solid stroke, gradient, glow) live under `host` so the occlusion mask applies
/// to every style. `removeFromOverlay()` drops the entire host tree (no orphan gradient/glow layers).
@MainActor
private final class BorderEntry {
    /// Root for this window's border; added to the overlay. Occlusion mask is applied here so
    /// solid / gradient / glow all respect the active-frontmost cutout policy.
    let host = CALayer()
    let shape = CAShapeLayer()
    /// Optional gradient/glow; children of `host`. Solid stroke uses `shape` alone.
    let gradient = CAGradientLayer()
    let glow = CAShapeLayer()
    /// Stroke-ring mask for the gradient fill (ring shape only; separate from occlusion).
    private let gradientStrokeMask = CAShapeLayer()
    /// Even-odd cutout of windows stacked above this border (host-level).
    private let occlusionMask = CAShapeLayer()
    var style: BorderStyle = .solid(RgbaColor(r: 0, g: 0, b: 0)) {
        didSet {
            if style != oldValue {
                color = style.primaryColor
                styleDirty = true
            }
        }
    }
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
    private var styleDirty = true

    /// Dirty-epoch membership: equal to manager's epoch means this id is already in dirtyList
    var dirtyEpoch: UInt32 = 0

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
        occlusionMask.fillRule = .evenOdd
        occlusionMask.fillColor = NSColor.black.cgColor
        strokeColor = color.cgColor
        glow.fillColor = NSColor.clear.cgColor
        glow.lineJoin = .round
        gradientStrokeMask.fillColor = NSColor.clear.cgColor
        gradientStrokeMask.strokeColor = NSColor.black.cgColor
        gradientStrokeMask.lineJoin = .round
        host.addSublayer(shape)
    }

    /// Detach every layer for this border (shape + gradient + glow) from the overlay.
    func removeFromOverlay() {
        host.removeFromSuperlayer()
    }

    /// The window rect outset by the border width - the area the border actually paints
    var region: Rect { WindowBordersMath.region(rect: rect, width: width) }

    /// Apply stroke geometry/style. Returns the panel frame in overlay coords (always current).
    /// Pure position change (same size/radius/width/overlay origin) only moves `host.frame` —
    /// path stays valid because stroke geometry is host-local.
    @discardableResult
    func applyStroke(originX: CGFloat, originY: CGFloat, zPosition: CGFloat) -> CGRect {
        let w = CGFloat(width)
        let panel = layerRect(rect, originX, originY).insetBy(dx: -w, dy: -w)

        let sizeOrStyleChanged = appliedWidth != width || appliedRadius != radius
            || appliedRect?.width != rect.width || appliedRect?.height != rect.height
            || appliedOriginX != originX || appliedOriginY != originY
        let positionChanged = appliedRect?.topLeftX != rect.topLeftX
            || appliedRect?.topLeftY != rect.topLeftY
            || sizeOrStyleChanged

        if sizeOrStyleChanged {
            appliedRect = rect
            appliedWidth = width
            appliedRadius = radius
            appliedOriginX = originX
            appliedOriginY = originY
            host.frame = panel
            let bounds = CGRect(origin: .zero, size: panel.size)
            shape.frame = bounds
            let strokeRect = CGRect(x: w / 2, y: w / 2, width: panel.width - w, height: panel.height - w)
            let r = CGFloat(radius) + w / 2
            let path = CGPath(roundedRect: strokeRect, cornerWidth: r, cornerHeight: r, transform: nil)
            shape.path = path
            shape.lineWidth = w
            styleDirty = true
        } else if positionChanged {
            // Translate only: same local path; move host in overlay space
            appliedRect = rect
            host.frame = panel
        }

        if styleDirty || sizeOrStyleChanged {
            styleDirty = false
            applyStylePaint(w: w)
        }
        if appliedStroke !== strokeColor {
            appliedStroke = strokeColor
            if case .solid = style {
                shape.strokeColor = strokeColor
            }
        }
        if appliedZ != zPosition {
            appliedZ = zPosition
            host.zPosition = zPosition
        }
        return panel
    }

    private func applyStylePaint(w: CGFloat) {
        let bounds = shape.frame
        switch style {
            case .solid(let c):
                gradient.removeFromSuperlayer()
                glow.removeFromSuperlayer()
                shape.strokeColor = c.cgColor
                shape.fillColor = NSColor.clear.cgColor
            case .gradient(let angle, let stops):
                glow.removeFromSuperlayer()
                // Ring-shaped stroke mask on the gradient; host-level occlusion is separate
                gradientStrokeMask.frame = bounds
                gradientStrokeMask.path = shape.path
                gradientStrokeMask.lineWidth = w
                gradient.frame = bounds
                gradient.colors = stops.map(\.cgColor) as [Any]
                gradient.startPoint = gradientPoints(angleDegrees: angle).0
                gradient.endPoint = gradientPoints(angleDegrees: angle).1
                gradient.mask = gradientStrokeMask
                shape.strokeColor = NSColor.clear.cgColor
                if gradient.superlayer !== host {
                    host.insertSublayer(gradient, below: shape)
                }
            case .glow(let c, let blur):
                gradient.removeFromSuperlayer()
                shape.strokeColor = c.cgColor
                glow.frame = bounds
                glow.path = shape.path
                glow.lineWidth = w * 2.5
                glow.strokeColor = c.nsColor.withAlphaComponent(0.45).cgColor
                glow.shadowColor = c.cgColor
                glow.shadowRadius = blur
                glow.shadowOpacity = 0.9
                glow.shadowOffset = .zero
                if glow.superlayer !== host {
                    host.insertSublayer(glow, below: shape)
                }
        }
    }

    /// Apply occlusion mask from a reusable buffer (no intermediate Array copy).
    func applyMask(panel: CGRect, occluders: ContiguousArray<Rect>, originX: CGFloat, originY: CGFloat) {
        if occluders.isEmpty {
            if hadOccluders {
                host.mask = nil
                occlusionMask.path = nil
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
        occlusionMask.frame = CGRect(origin: .zero, size: panel.size)
        occlusionMask.path = path // even-odd fill -> full panel minus the covered rects
        // Host mask clips solid stroke, gradient, and glow together
        host.mask = occlusionMask
    }
}

private func gradientPoints(angleDegrees: Double) -> (CGPoint, CGPoint) {
    let rad = angleDegrees * .pi / 180
    let dx = cos(rad) * 0.5
    let dy = sin(rad) * 0.5
    return (CGPoint(x: 0.5 - dx, y: 0.5 - dy), CGPoint(x: 0.5 + dx, y: 0.5 + dy))
}

/// WindowServer move/resize callback (runs on the thread that registered it - the main thread).
/// `data` points to the moved window's CGWindowID. Handing it straight to the manager is how border
/// masks track a live drag at the display's refresh rate instead of waiting for AeroSpace's refresh.
/// Also drives mouse-resize sibling reflow (~60fps) via `MouseResizeDriver`.
let windowBordersEventProc: SkyLight.NotifyProc = { _, data, _, _ in
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
    /// Window ids currently carrying a border (for WS notify subscription during mouse-resize).
    var borderedWindowIds: [UInt32] { Array(entries.keys) }
    /// All on-screen normal windows (excluding our overlay), front-to-back. Used to compute which
    /// windows cover a given border. Rebuilt on each full refresh; a drag only updates the moved rect
    private var stack: [(id: UInt32, rect: Rect)] = []
    /// O(1) id -> stack index. Kept in lockstep with `stack` so move events never scan the array
    private var stackIndex: [UInt32: Int] = [:]
    /// Membership set for occlusion "managed" skips. Rebuilt only when entries gain/lose ids.
    private var managedIds: Set<UInt32> = []
    /// The focused window. Treated as the frontmost window for border purposes: its border is never
    /// masked by another managed window and draws on top, and inactive borders are always clipped
    /// under it. Tiling rarely restacks tiles, so the raw on-screen stack can't be trusted to put the
    /// focused window above a neighbour that overflowed onto it
    private var activeId: UInt32?
    private var observingWindowServer = false
    /// Per-window chrome class for corner-radius probes (plain vs toolbar). Filled async once.
    private var chromeCache: [UInt32: WindowCornerRadius.Chrome] = [:]

    // MARK: Coalesced dirty redraw (zero-heap on the mark path)

    /// Border ids that need stroke and/or mask recompute. ContiguousArray + epoch — no Set hashing.
    private var dirtyList: ContiguousArray<UInt32> = []
    /// Bumped after each flush. Entry is dirty iff `entry.dirtyEpoch == dirtyEpoch`.
    private var dirtyEpoch: UInt32 = 1
    /// Reused every paint so occluder collection never reallocates under steady load.
    private var occluderScratch = ContiguousArray<Rect>()

    private init() {
        dirtyList.reserveCapacity(16)
        occluderScratch.reserveCapacity(8)
    }

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

        // Shared with windowLevelCache: one CGWindowList scan per refresh session. Build the
        // stack first so bordered windows can reuse those rects instead of N SLSGetWindowBounds
        rebuildStack(onScreenWindowSnapshot().normalStack)

        activeId = focus.windowOrNil?.windowId
        var seen = Set<UInt32>(minimumCapacity: entries.count)
        var membershipChanged = false
        for workspace in Workspace.allUnsorted where workspace.isVisible {
            for window in workspace.allLeafWindowsRecursive {
                guard let rect = resolvedBorderRect(for: window) else { continue }
                seen.insert(window.windowId)
                if entries[window.windowId] == nil { membershipChanged = true }
                let entry = entries[window.windowId] ?? makeEntry(window.windowId, rect: rect)
                entry.rect = rect
                entry.style = window.windowId == activeId ? cfg.resolvedActiveStyle() : cfg.resolvedInactiveStyle()
                entry.color = entry.style.primaryColor
                entry.width = cfg.width
                let chrome = chromeCache[window.windowId] ?? .plain
                entry.radius = cfg.cornerRadius(forAppId: window.app.rawAppBundleId, chrome: chrome)
                if cfg.detectCornerRadius, chromeCache[window.windowId] == nil {
                    scheduleChromeProbe(window)
                }
            }
        }
        for (id, entry) in entries where !seen.contains(id) {
            entry.removeFromOverlay()
            entries.removeValue(forKey: id)
            chromeCache.removeValue(forKey: id)
            membershipChanged = true
        }
        if membershipChanged {
            managedIds = Set(entries.keys)
        }
        // Continuous drag-rate move/resize delivery requires an explicit window id list
        // (SLSRegisterNotifyProc alone is not enough — JankyBorders does this every rebuild)
        requestWindowServerNotifications()

        // Config / membership / stack order may have changed - full recompute once, immediately
        // (refresh is already session-batched; no need to coalesce further)
        flushAll()
    }

    /// Classify window chrome (toolbar vs plain) once so radius can track Tahoe's split.
    private func scheduleChromeProbe(_ window: Window) {
        let id = window.windowId
        let appId = window.app.rawAppBundleId
        Task { @MainActor in
            let chrome = await detectWindowChrome(window)
            let prev = chromeCache[id]
            chromeCache[id] = chrome
            guard prev != chrome, let entry = entries[id] else { return }
            let cfg = config.windowBorders
            entry.radius = cfg.cornerRadius(forAppId: appId, chrome: chrome)
            markDirty(id)
            flushDirtyList()
        }
    }

    private func detectWindowChrome(_ window: Window) async -> WindowCornerRadius.Chrome {
        guard let mac = window as? MacWindow else { return .plain }
        do {
            if try await mac.macApp.windowHasAxToolbar(mac.windowId, .cancellable) {
                return .toolbar
            }
        } catch {
            // AX flake → plain probe radius
        }
        return .plain
    }

    /// Prefer live on-screen bounds so a user drag is not frozen to lastApplied. Only use
    /// lastApplied when we just wrote the frame and SkyLight may lag (see `resolveBorderRect`).
    private func resolvedBorderRect(for window: Window) -> Rect? {
        let id = window.windowId
        let applied = window.lastAppliedLayoutPhysicalRect
        let mayBeStale = skyLightFrameMayBeStale(id)
        // Skip SLS when we just wrote this frame — lastApplied is authoritative until lag clears
        if mayBeStale, applied != nil {
            return resolveBorderRect(lastApplied: applied, mayBeStale: true, liveBounds: nil, stackRect: nil)
        }
        let live = WindowServerReads.current.windowBounds(windowId: id, forOverlay: true)
        let stackRect = stackIndex[id].map { stack[$0].rect }
        return resolveBorderRect(
            lastApplied: applied,
            mayBeStale: false,
            liveBounds: live,
            stackRect: stackRect,
        )
    }

    /// Tell WindowServer which windows we care about for move/resize notify delivery.
    private func requestWindowServerNotifications() {
        var ids: [UInt32] = []
        ids.reserveCapacity(entries.count + stack.count)
        ids.append(contentsOf: entries.keys)
        for item in stack where entries[item.id] == nil {
            ids.append(item.id)
        }
        SkyLight.requestNotifications(for: ids)
    }

    /// A window moved/resized (WindowServer event). This callback fires for EVERY window on the
    /// system. Cost model for the pure-math part (must stay **nanoseconds** on modest hardware):
    /// 1. O(1) rect update via stackIndex
    /// 2. Early-out if the move can't affect any border (unrelated animation) — no heap
    /// 3. Mark dirty via epoch + ContiguousArray append — no Set, no region snapshot array
    /// 4. Coalesce all events in this run-loop turn into ONE Core Animation transaction
    func handleWindowMoved(windowId: UInt32) {
        // Display-rate samples of the drag target drive sibling reflow (~60fps). Must run even
        // when borders are disabled so resize smoothness does not depend on the overlay.
        MouseResizeDriver.noteWindowServerFrame(windowId: windowId)

        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }
        guard let rect = resolvedLiveBorderRect(windowId: windowId) else { return }
        applyBorderRect(windowId: windowId, rect: rect, flush: true)
    }

    /// After mouse-drag layout: paint **all** tile borders from layout geometry (lastApplied).
    /// Mixing live WS for the drag target with layout for siblings made the shared edge thrash.
    func syncAfterMouseLayout() {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }
        var any = false
        for (id, entry) in entries {
            guard let rect = Window.get(byId: id)?.lastAppliedLayoutPhysicalRect
                ?? WindowServerReads.current.windowBounds(windowId: id, forOverlay: true)
            else { continue }
            if entry.rect != rect {
                applyBorderRect(windowId: id, rect: rect, flush: false)
                any = true
            } else {
                markDirty(id)
                any = true
            }
        }
        if any { flushDirtyList() }
    }

    /// Frame source for a WindowServer move/resize notify.
    /// - During mouse manipulate: prefer layout lastApplied for every window so borders stay
    ///   locked to the tile grid (live drag frame ≠ layout allocation → L/R thrash).
    /// - After our own AX write: prefer lastApplied until SkyLight catches up.
    /// - Otherwise: live WindowServer bounds.
    private func resolvedLiveBorderRect(windowId: UInt32) -> Rect? {
        let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true)
        let applied = Window.get(byId: windowId)?.lastAppliedLayoutPhysicalRect
        if currentlyManipulatedWithMouseWindowId != nil, let applied {
            return applied
        }
        if skyLightFrameMayBeStale(windowId), let applied {
            return applied
        }
        return live
    }

    /// Update entry + stack rect and mark dirty. `flush: false` batches into `syncAfterMouseLayout`.
    private func applyBorderRect(windowId: UInt32, rect: Rect, flush: Bool) {
        let oldRect: Rect?
        if let i = stackIndex[windowId] {
            oldRect = stack[i].rect
            if oldRect == rect {
                entries[windowId]?.rect = rect
                if flush { return }
                // still fall through when batching so occlusion can refresh
            } else {
                stack[i].rect = rect
            }
        } else {
            oldRect = nil
            stackIndex[windowId] = stack.count
            stack.append((windowId, rect))
        }
        entries[windowId]?.rect = rect

        let moverIsBordered = entries[windowId] != nil
        if !moverIsBordered {
            let hitsNew = overlapsAnyBorderInPlace(rect)
            let hitsOld = oldRect.map(overlapsAnyBorderInPlace) ?? false
            guard hitsNew || hitsOld else { return }
        }

        markAffectedBorders(mover: windowId, moverIsBordered: moverIsBordered, oldRect: oldRect, newRect: rect)
        if flush {
            // Paint immediately so the border tracks the window on this event.
            flushDirtyList()
        }
    }

    // MARK: Dirty set

    /// Allocation-free overlap test against live entries (hot path for unrelated window animations)
    private func overlapsAnyBorderInPlace(_ rect: Rect) -> Bool {
        for (_, entry) in entries {
            if WindowBordersMath.rectsIntersect(entry.region, rect) { return true }
        }
        return false
    }

    /// Mark borders whose stroke/mask can change. Zero heap (epoch de-dupe + ContiguousArray).
    private func markAffectedBorders(mover: UInt32, moverIsBordered: Bool, oldRect: Rect?, newRect: Rect) {
        if moverIsBordered { markDirty(mover) }
        for (id, entry) in entries {
            if id == mover { continue }
            let region = entry.region
            if let old = oldRect, WindowBordersMath.rectsIntersect(region, old) {
                markDirty(id)
                continue
            }
            if WindowBordersMath.rectsIntersect(region, newRect) {
                markDirty(id)
            }
        }
    }

    @inline(__always)
    private func markDirty(_ id: UInt32) {
        guard let entry = entries[id], entry.dirtyEpoch != dirtyEpoch else { return }
        entry.dirtyEpoch = dirtyEpoch
        dirtyList.append(id)
    }

    private func flushAll() {
        flush { paint in
            for (id, entry) in entries {
                paint(id, entry)
            }
        }
        // Drop any pending partial dirties — full paint just ran
        dirtyList.removeAll(keepingCapacity: true)
        bumpDirtyEpoch()
    }

    private func flushDirtyList() {
        guard !dirtyList.isEmpty else { return }
        // Paint from dirtyList in place (no CoW copy), then clear + bump epoch
        flush { paint in
            for id in dirtyList {
                guard let entry = entries[id] else { continue }
                paint(id, entry)
            }
        }
        dirtyList.removeAll(keepingCapacity: true)
        bumpDirtyEpoch()
    }

    private func bumpDirtyEpoch() {
        dirtyEpoch &+= 1
        if dirtyEpoch == 0 {
            // Wrap: clear per-entry markers so epoch 1 is unambiguous
            dirtyEpoch = 1
            for (_, entry) in entries { entry.dirtyEpoch = 0 }
        }
    }

    private func flush(_ body: (_ paint: (UInt32, BorderEntry) -> Void) -> Void) {
        let originX = overlay.frame.origin.x
        let originY = overlay.frame.origin.y
        let activeRect = activeId.flatMap { entries[$0]?.rect }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body { id, entry in
            paint(id: id, entry: entry, originX: originX, originY: originY, activeRect: activeRect)
        }
        CATransaction.commit()
    }

    private func paint(
        id: UInt32,
        entry: BorderEntry,
        originX: CGFloat,
        originY: CGFloat,
        activeRect: Rect?,
    ) {
        let panel = entry.applyStroke(originX: originX, originY: originY, zPosition: id == activeId ? 1 : 0)
        WindowBordersMath.collectOccluders(
            id: id,
            region: entry.region,
            isActive: id == activeId,
            activeId: activeId,
            activeRect: activeRect,
            stack: stack,
            stackIndex: stackIndex[id],
            managedIds: managedIds,
            into: &occluderScratch,
        )
        entry.applyMask(panel: panel, occluders: occluderScratch, originX: originX, originY: originY)
    }

    private func makeEntry(_ id: UInt32, rect: Rect) -> BorderEntry {
        let entry = BorderEntry(rect: rect)
        overlay.root.addSublayer(entry.host)
        entries[id] = entry
        managedIds.insert(id)
        return entry
    }

    private func teardownAll() {
        dirtyList.removeAll(keepingCapacity: true)
        bumpDirtyEpoch()
        for (_, entry) in entries { entry.removeFromOverlay() }
        entries.removeAll()
        managedIds.removeAll()
        chromeCache.removeAll()
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
