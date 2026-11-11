import AppKit
import Common
import CoreGraphics

/// WindowServer events for managed windows (move/resize, shown/hidden, destroyed), plus the display
/// facts the side UI needs. The one place these private calls happen.
@MainActor
enum WindowServerEvents {
    private static var delivering = false

    /// Deliver move/resize events to `WindowBordersManager.handleWindowMoved` (which also drives
    /// mouse-resize). Idempotent: borders and mouse-resize each registered the same proc, and with
    /// both on every event arrived twice.
    static func startDelivering() {
        if delivering { return }
        delivering = true
        SkyLight.registerWindowEvents(windowServerEventProc)
    }

    static func request(_ windowIds: [UInt32]) { SkyLight.requestNotifications(for: windowIds) }

    /// See `SkyLight.setBrightness`
    static func setBrightness(_ windowIds: [UInt32], _ value: Float) {
        guard Headless.permits(.skyLightWindow) else { return }
        SkyLight.setBrightness(windowIds, value)
    }
    static func remove(_ windowIds: [UInt32]) { SkyLight.removeNotifications(for: windowIds) }

    static func currentSpaceIsFullscreen(_ displayId: CGDirectDisplayID) -> Bool {
        SkyLight.currentSpaceIsFullscreen(displayId: displayId)
    }

    static func displayBounds(_ displayId: CGDirectDisplayID) -> CGRect { CGDisplayBounds(displayId) }

    /// Raw SkyLight border windows can be created in this process
    static var canDrawBorders: Bool { BorderSkyLight.isAvailable }
}

/// WindowServer move/resize callback (runs on the thread that registered it - the main thread).
/// `data` points to the moved window's CGWindowID. SkyLight hands over a datagram buffer that is
/// not always 4-byte aligned, and `load(as:)` traps on a misaligned pointer, so read it unaligned.
private let windowServerEventProc: SkyLight.NotifyProc = { event, data, _, _ in
    guard let data else { return }
    let windowId = data.loadUnaligned(as: UInt32.self)
    if Thread.isMainThread {
        MainActor.assumeIsolated { WindowServerEvents.handle(event: event, windowId: windowId) }
    } else {
        DispatchQueue.main.async { WindowServerEvents.handle(event: event, windowId: windowId) }
    }
}

extension WindowServerEvents {
    enum Reaction: Equatable { case repaintBorder, refresh, ignore }

    /// What the model believes about a window, as far as shown/hidden events go
    enum Belief: Equatable {
        case untracked
        /// Tiled or floating on a visible workspace
        case visible
        /// Minimized or its app hidden: macOS took it off screen
        case hiddenByMacos
        /// Anything else: parked on an invisible workspace, a background native tab, fullscreen
        case other
    }

    /// Move/resize repaint the border. Shown/hidden/destroyed re-run discovery only when they
    /// contradict the model: a backup for AX notifications an app posts late or never. Shown and
    /// hidden fire far more often than the model changes (native tab switches order windows in and
    /// out): refreshing on every one ran ~750 full discoveries in a few hours, 66 in one minute.
    static func reaction(event: UInt32, belief: Belief) -> Reaction {
        switch SkyLight.WindowEvent(rawValue: event) {
            case .move, .resize: .repaintBorder
            case .destroyed: belief == .untracked ? .ignore : .refresh
            case .shown: belief == .hiddenByMacos ? .refresh : .ignore
            case .hidden: belief == .visible ? .refresh : .ignore
            case nil: .ignore
        }
    }

    /// At most one event-triggered discovery per window per this many seconds (a flickering window)
    static let refreshCooldownSeconds: Double = 2
    private static var lastRefreshAt: [UInt32: TimeInterval] = [:]

    static func handle(event: UInt32, windowId: UInt32) {
        switch reaction(event: event, belief: belief(windowId)) {
            case .repaintBorder: WindowBordersManager.shared.handleWindowMoved(windowId: windowId)
            case .refresh:
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastRefreshAt[windowId], now - last < refreshCooldownSeconds { return }
                lastRefreshAt[windowId] = now
                if lastRefreshAt.count > 256 { lastRefreshAt = lastRefreshAt.filter { now - $0.value < refreshCooldownSeconds } }
                let name = SkyLight.WindowEvent(rawValue: event).map { "\($0)" } ?? "\(event)"
                onAxWindowListChanged(notif: "ws-\(name)")
            case .ignore: break
        }
    }

    private static func belief(_ windowId: UInt32) -> Belief {
        guard let window = Window.get(byId: windowId) else { return .untracked }
        if window.isOwnedByMacos {
            return window.isParkedAsNativeTab || window.parent is MacosFullscreenWindowsContainer ? .other : .hiddenByMacos
        }
        return window.nodeWorkspace?.isVisible == true ? .visible : .other
    }
}
