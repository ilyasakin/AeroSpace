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
        borderLayer.strokeColor = color.nsColor.cgColor
        borderLayer.lineWidth = w
        CATransaction.commit()

        if windowNumber > 0 {
            SkyLight.orderWindow(UInt32(windowNumber), above: targetWindowId)
        }
    }
}

/// Manages one border panel per visible managed window. Driven from the refresh loop, so borders
/// update on every focus / move / resize / layout change with no separate tracking process
@MainActor
final class WindowBordersManager {
    static let shared = WindowBordersManager()
    private var panels: [UInt32: WindowBordersPanel] = [:]
    private init() {}

    func refresh() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled else {
            teardownAll()
            return
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
                panel.update(windowAppKitFrame: rect.toAppKitFrame(), targetWindowId: window.windowId, color: color, width: cfg.width, cornerRadius: cfg.cornerRadius)
            }
        }

        for (id, panel) in panels where !seen.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
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
