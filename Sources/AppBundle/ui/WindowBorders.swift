import AppKit

extension RgbaColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
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
        guard !union.isNull else { return }
        setFrame(union, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: union.size)
        CATransaction.commit()
    }
}

/// One managed window's border: a stroked rounded rect plus a mask that hides the parts covered by
/// windows stacked above it
@MainActor
private final class BorderEntry {
    let shape = CAShapeLayer()
    let mask = CAShapeLayer()
    var color: RgbaColor = RgbaColor(r: 0, g: 0, b: 0)
    var width = 0
    var radius = 0
    var rect: Rect // live top-left-global frame of the target window

    init(rect: Rect) {
        self.rect = rect
        shape.fillColor = NSColor.clear.cgColor
        shape.lineJoin = .round
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
    }

    /// The window rect outset by the border width - the area the border actually paints
    var region: Rect {
        let w = CGFloat(width)
        return Rect(topLeftX: rect.topLeftX - w, topLeftY: rect.topLeftY - w,
                    width: rect.width + 2 * w, height: rect.height + 2 * w)
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
    /// The focused window. Treated as the frontmost window for border purposes: its border is never
    /// masked by another managed window and draws on top, and inactive borders are always clipped
    /// under it. Tiling rarely restacks tiles, so the raw on-screen stack can't be trusted to put the
    /// focused window above a neighbour that overflowed onto it
    private var activeId: UInt32?
    private var observingWindowServer = false
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

        stack = onScreenStack()
        redraw()
    }

    /// A window moved/resized (WindowServer event). This callback fires for EVERY window on the
    /// system, so we redraw only when the move actually affects a border: either the mover is bordered,
    /// or it overlaps a bordered window (as an occluder) at its old or new position. Everything else -
    /// an unrelated app animating a window - updates the cached rect and returns without touching the GPU
    func handleWindowMoved(windowId: UInt32) {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }
        guard let rect = SkyLight.overlayBounds(windowId) else { return }
        let oldRect = stack.first(where: { $0.id == windowId })?.rect
        if let i = stack.firstIndex(where: { $0.id == windowId }) { stack[i].rect = rect }
        entries[windowId]?.rect = rect

        let affectsBorder = entries[windowId] != nil
            || overlapsAnyBorder(rect)
            || (oldRect.map(overlapsAnyBorder) ?? false)
        guard affectsBorder else { return }
        redraw()
    }

    private func overlapsAnyBorder(_ rect: Rect) -> Bool {
        entries.contains { rectsIntersect($0.value.region, rect) }
    }

    /// Rebuild every border's stroke path + occlusion mask from the current rects and stack
    private func redraw() {
        let originX = overlay.frame.origin.x
        let originY = overlay.frame.origin.y
        let indexById: [UInt32: Int] = Dictionary(stack.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, entry) in entries {
            let w = CGFloat(entry.width)
            let panel = layerRect(entry.rect, originX, originY).insetBy(dx: -w, dy: -w)
            entry.shape.frame = panel
            let strokeRect = CGRect(x: w / 2, y: w / 2, width: panel.width - w, height: panel.height - w)
            let radius = CGFloat(entry.radius) + w / 2
            entry.shape.path = CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            entry.shape.strokeColor = entry.color.nsColor.cgColor
            entry.shape.lineWidth = w
            // Draw the active window's border above every inactive one where they overlap
            entry.shape.zPosition = id == activeId ? 1 : 0

            // Mask out the regions covered by windows stacked above this one
            let occluders = occluders(of: id, outset: entry, indexById: indexById)
            if occluders.isEmpty {
                entry.shape.mask = nil
            } else {
                let path = CGMutablePath()
                path.addRect(CGRect(origin: .zero, size: panel.size))
                for occ in occluders {
                    let local = layerRect(occ, originX, originY)
                    path.addRect(CGRect(x: local.minX - panel.minX, y: local.minY - panel.minY, width: local.width, height: local.height))
                }
                entry.mask.frame = CGRect(origin: .zero, size: panel.size)
                entry.mask.path = path // even-odd fill -> full panel minus the covered rects
                entry.shape.mask = entry.mask
            }
        }
        CATransaction.commit()
    }

    /// Top-left-global rects of windows that cover `id`'s (outset) border region. Normally these are
    /// the windows stacked above it, but the active window is forced to be frontmost: it is never
    /// occluded by another managed (inactive) window, and it always occludes every inactive window
    private func occluders(of id: UInt32, outset entry: BorderEntry, indexById: [UInt32: Int]) -> [Rect] {
        let region = entry.region
        let isActive = id == activeId
        var result: [Rect] = []
        var included = Set<UInt32>()
        if let idx = indexById[id] {
            for i in 0 ..< idx where rectsIntersect(region, stack[i].rect) {
                // The active border is never masked by another managed (inactive) window, even if the
                // raw stack puts an overflowing neighbour above it
                if isActive, entries[stack[i].id] != nil { continue }
                result.append(stack[i].rect)
                included.insert(stack[i].id)
            }
        }
        // An inactive border is always clipped under the active window where they overlap
        if !isActive, let activeId, !included.contains(activeId),
           let active = entries[activeId], rectsIntersect(region, active.rect)
        {
            result.append(active.rect)
        }
        return result
    }

    private func makeEntry(_ id: UInt32, rect: Rect) -> BorderEntry {
        let entry = BorderEntry(rect: rect)
        overlay.root.addSublayer(entry.shape)
        entries[id] = entry
        return entry
    }

    private func teardownAll() {
        for (_, entry) in entries { entry.shape.removeFromSuperlayer() }
        entries.removeAll()
        stack.removeAll()
        overlay.orderOut(nil)
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

    /// A top-left-global Rect converted to overlay-layer coordinates (bottom-left, overlay-relative)
    private func layerRect(_ r: Rect, _ originX: CGFloat, _ originY: CGFloat) -> CGRect {
        let ak = r.toAppKitFrame()
        return CGRect(x: ak.origin.x - originX, y: ak.origin.y - originY, width: ak.width, height: ak.height)
    }
}

private func rectsIntersect(_ a: Rect, _ b: Rect) -> Bool {
    a.topLeftX < b.topLeftX + b.width && b.topLeftX < a.topLeftX + a.width &&
        a.topLeftY < b.topLeftY + b.height && b.topLeftY < a.topLeftY + a.height
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
