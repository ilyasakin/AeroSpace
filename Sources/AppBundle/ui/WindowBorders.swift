import AppKit

extension RgbaColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A transparent, click-through overlay panel that strokes a border around one target window.
/// Drawn with a CAShapeLayer (no SwiftUI/AX overhead) so it's cheap to update every refresh
final class WindowBordersPanel: NSPanelHud {
    private let borderLayer = CAShapeLayer()
    // Last geometry applied, so a move/resize event can reposition without re-deriving width/radius
    private var lastWidth = 0
    private var lastCornerRadius = 0

    override init() {
        super.init()
        hasShadow = false
        ignoresMouseEvents = true
        // Normal level (not .floating) so SLSOrderWindow can place the border just above its own
        // target window in the global stack — a background window's border stays below the window
        // in front of it, instead of every border floating over everything
        level = .normal
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(borderLayer)
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineJoin = .round
        contentView = view
    }

    /// - windowAppKitFrame: the target window's frame in AppKit (bottom-left origin) coordinates
    /// - targetWindowId: the CGWindowID this border belongs to, used to order the border above it
    func update(windowAppKitFrame: NSRect, targetWindowId: UInt32, color: RgbaColor, width: Int, cornerRadius: Int) {
        borderLayer.strokeColor = color.nsColor.cgColor
        applyGeometry(windowAppKitFrame, width: width, cornerRadius: cornerRadius)
        reorderAbove(targetWindowId)
    }

    /// Cheap reposition for a WindowServer move/resize event: reuse the last color/width/radius and
    /// only move the frame + re-glue z-order. No config or window lookup, so it's fast enough to run
    /// per frame while a window is being dragged
    func reposition(windowAppKitFrame: NSRect, targetWindowId: UInt32) {
        applyGeometry(windowAppKitFrame, width: lastWidth, cornerRadius: lastCornerRadius)
        reorderAbove(targetWindowId)
    }

    private func applyGeometry(_ windowAppKitFrame: NSRect, width: Int, cornerRadius: Int) {
        lastWidth = width
        lastCornerRadius = cornerRadius
        let w = CGFloat(width)
        // Panel is the window frame outset by the border width so the stroke sits around the window
        let panelFrame = windowAppKitFrame.insetBy(dx: -w, dy: -w)
        // Stroke centerline runs w/2 outside the window edge -> the border hugs the window's outside
        let strokeRect = CGRect(x: w / 2, y: w / 2, width: panelFrame.width - w, height: panelFrame.height - w)
        let radius = CGFloat(cornerRadius) + w / 2

        // Disable implicit CALayer animations so borders track window motion instantly
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(panelFrame, display: false)
        borderLayer.frame = CGRect(origin: .zero, size: panelFrame.size)
        borderLayer.path = CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        borderLayer.lineWidth = w
        CATransaction.commit()
    }

    /// Re-issue only the z-order (no frame/path recompute). Used to reassert the stack after an
    /// async window raise, which strands this border below the window that was previously on top
    func reorderAbove(_ targetWindowId: UInt32) {
        if windowNumber > 0 {
            SkyLight.orderWindow(UInt32(windowNumber), above: targetWindowId)
        }
    }
}

/// Manages one border panel per visible managed window. Driven from the refresh loop, so borders
/// update on every focus / move / resize / layout change with no separate tracking process
/// WindowServer event callback (runs on the thread that registered it, i.e. the main thread).
/// `data` points to the affected window's CGWindowID. We hand it to the manager to move/re-glue
/// just that window's border, which is how borders track a live drag at the display's refresh rate
/// instead of waiting for AeroSpace's next refresh
private let windowBordersEventProc: SkyLight.NotifyProc = { event, data, _, _ in
    guard let data else { return }
    let windowId = data.load(as: UInt32.self)
    let isReorder = event == SkyLight.WindowEvent.reorder.rawValue || event == SkyLight.WindowEvent.level.rawValue
    if Thread.isMainThread {
        MainActor.assumeIsolated { WindowBordersManager.shared.handleWindowServerEvent(windowId: windowId, isReorder: isReorder) }
    } else {
        DispatchQueue.main.async { WindowBordersManager.shared.handleWindowServerEvent(windowId: windowId, isReorder: isReorder) }
    }
}

@MainActor
final class WindowBordersManager {
    static let shared = WindowBordersManager()
    private var panels: [UInt32: WindowBordersPanel] = [:]
    private var observingWindowServer = false
    private init() {}

    /// Move or re-glue a single window's border in response to a WindowServer event. Cheap and
    /// panel-local: unknown windows (no border) are ignored, so this also filters our own overlays
    func handleWindowServerEvent(windowId: UInt32, isReorder: Bool) {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled else { return }
        guard let panel = panels[windowId] else { return }
        if isReorder {
            panel.reorderAbove(windowId)
        } else if let rect = SkyLight.overlayBounds(windowId) {
            panel.reposition(windowAppKitFrame: rect.toAppKitFrame(), targetWindowId: windowId)
        }
    }

    func refresh() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled else {
            teardownAll()
            return
        }
        // Subscribe lazily the first time borders are enabled; kept for the app's lifetime
        if !observingWindowServer {
            observingWindowServer = true
            SkyLight.registerWindowEvents(windowBordersEventProc)
        }
        let activeId = focus.windowOrNil?.windowId
        var seen = Set<UInt32>(minimumCapacity: panels.count)

        for workspace in Workspace.allUnsorted where workspace.isVisible {
            for window in workspace.allLeafWindowsRecursive {
                // Live on-screen frame (tracks mouse drags); fall back to the last applied layout
                guard let rect = SkyLight.overlayBounds(window.windowId) ?? window.lastAppliedLayoutPhysicalRect else { continue }
                seen.insert(window.windowId)
                let panel = panels[window.windowId] ?? makePanel(for: window.windowId)
                let color = window.windowId == activeId ? cfg.activeColor : cfg.inactiveColor
                let cornerRadius = cfg.cornerRadius(forAppId: window.app.rawAppBundleId)
                panel.update(windowAppKitFrame: rect.toAppKitFrame(), targetWindowId: window.windowId, color: color, width: cfg.width, cornerRadius: cornerRadius)
            }
        }

        for (id, panel) in panels where !seen.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
        }
    }

    /// Reassert every border's z-position above its own target window, without recomputing frames.
    /// Cheap (just SLSOrderWindow calls). Call this right after AeroSpace initiates a window raise:
    /// the raise is async in WindowServer, so the border ordering done during the focus-change
    /// refresh runs against the pre-raise stack and leaves the focused window's border stranded
    /// below the window that used to be on top
    func reassertZOrder() {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled else { return }
        for (targetId, panel) in panels {
            panel.reorderAbove(targetId)
        }
    }

    private func makePanel(for id: UInt32) -> WindowBordersPanel {
        let panel = WindowBordersPanel()
        panel.orderFrontRegardless() // realize the window so windowNumber is valid; update() then orders it precisely
        panels[id] = panel
        return panel
    }

    private func teardownAll() {
        for (_, panel) in panels { panel.close() }
        panels.removeAll()
    }
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
