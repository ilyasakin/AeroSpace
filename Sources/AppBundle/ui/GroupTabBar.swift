import AppKit
import Common

/// Interactive tab strip for accordion group containers (M4). Click-focuses the child window.
///
/// The overlay covers all screens for positioning, but only tab buttons receive hits — empty
/// regions return nil from hit-testing so clicks fall through to windows below (otherwise a
/// full-screen panel with ignoresMouseEvents=false would freeze the desktop).
@MainActor
final class GroupTabBarManager {
    static let shared = GroupTabBarManager()
    private let overlay = GroupTabBarOverlay()
    private var tabButtons: [NSView] = []

    private init() {}

    func refresh() {
        guard TrayMenuModel.shared.isEnabled else {
            overlay.orderOut(nil)
            clearTabs()
            return
        }
        overlay.coverAllScreens()
        clearTabs()

        for workspace in Workspace.allUnsorted where workspace.isVisible {
            collectAccordionGroups(workspace.rootTilingContainer)
        }

        if tabButtons.isEmpty {
            overlay.orderOut(nil)
        } else {
            overlay.orderFrontRegardless()
        }
    }

    private func collectAccordionGroups(_ node: TreeNode) {
        if let container = node as? TilingContainer, container.layout == .accordion,
           let rect = container.lastAppliedLayoutPhysicalRect ?? container.children.first?.lastAppliedLayoutPhysicalRect
        {
            addTabs(for: container, in: rect)
        }
        for child in node.children {
            collectAccordionGroups(child)
        }
    }

    private func addTabs(for container: TilingContainer, in rect: Rect) {
        let children = container.children
        guard children.count >= 2 else { return }
        let tabH: CGFloat = 22
        // Same flip as WindowBorders: AeroSpace top-left → AppKit bottom-left via mainMonitor.height
        let ak = rect.toAppKitFrame()
        let overlayOrigin = overlay.frame.origin
        // Top edge of the group in overlay content coords (AppKit y-up)
        let topY = ak.minY + ak.height - tabH - overlayOrigin.y
        let baseX = ak.minX - overlayOrigin.x
        let tabW = ak.width / CGFloat(children.count)
        let mru = container.mostRecentChild

        for (i, child) in children.enumerated() {
            let button = GroupTabButton(
                frame: NSRect(x: baseX + CGFloat(i) * tabW, y: topY, width: tabW, height: tabH),
                title: tabTitle(for: child),
                isActive: child === mru,
                windowId: (child as? Window)?.windowId,
            )
            button.onClick = { [weak self] windowId in
                guard let windowId, let window = Window.get(byId: windowId) else { return }
                _ = window.focusWindow()
                self?.refresh()
            }
            overlay.contentView?.addSubview(button)
            tabButtons.append(button)
        }
    }

    private func tabTitle(for node: TreeNode) -> String {
        if let w = node as? Window {
            return "Window \(w.windowId)"
        }
        if let c = node as? TilingContainer {
            return "Group (\(c.children.count))"
        }
        return "…"
    }

    private func clearTabs() {
        for b in tabButtons { b.removeFromSuperview() }
        tabButtons.removeAll()
    }
}

@MainActor
private final class GroupTabBarOverlay: NSPanelHud {
    private var lastUnion = CGRect.null

    override init() {
        super.init()
        ignoresMouseEvents = false // tabs need clicks; empty areas pass through via hitTest
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        contentView = GroupTabBarContentView()
    }

    /// See StatusBarPanel — AX hit-tests can run off MainActor under focus-follows-mouse.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

    func coverAllScreens() {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull, union != lastUnion else { return }
        lastUnion = union
        setFrame(union, display: false)
    }
}

/// Full-screen content view that only claims hits on tab-button subviews.
/// Returning nil for empty regions lets clicks fall through to windows beneath the panel.
@MainActor
private final class GroupTabBarContentView: NSView {
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let hit = super.hitTest(point)
            // Empty chrome: do not capture. Only descendants (tab buttons) receive events.
            return hit === self ? nil : hit
        }
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }
}

@MainActor
private final class GroupTabButton: NSView {
    var onClick: ((UInt32?) -> Void)?
    private let windowId: UInt32?
    private let label = NSTextField(labelWithString: "")

    init(frame: NSRect, title: String, isActive: Bool, windowId: UInt32?) {
        self.windowId = windowId
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = (isActive ? NSColor.controlAccentColor : NSColor.windowBackgroundColor)
            .withAlphaComponent(isActive ? 0.95 : 0.75).cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.refusesFirstResponder = true
        label.frame = bounds.insetBy(dx: 4, dy: 2)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Claim the whole button rect so the label does not steal mouseDown.
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?(windowId)
    }
}

/// Pure placement helper for unit tests: top strip of a group rect in overlay content coords.
@MainActor
func groupTabStripFrame(
    containerRect: Rect,
    overlayOrigin: CGPoint,
    tabHeight: CGFloat,
    tabIndex: Int,
    tabCount: Int,
) -> NSRect {
    let ak = containerRect.toAppKitFrame()
    let topY = ak.minY + ak.height - tabHeight - overlayOrigin.y
    let baseX = ak.minX - overlayOrigin.x
    let tabW = ak.width / CGFloat(tabCount)
    return NSRect(x: baseX + CGFloat(tabIndex) * tabW, y: topY, width: tabW, height: tabHeight)
}

/// Pure hit-test policy for the tab bar content view (unit-tested without AppKit hit-testing).
/// Returns true when a hit on `hit` should be discarded so the click falls through.
func groupTabBarShouldPassThrough(hitIsContentView: Bool) -> Bool {
    hitIsContentView
}
