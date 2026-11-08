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

    /// Move/resize repaint the border. Shown/hidden/destroyed of a tracked window re-run discovery:
    /// a backup for AX notifications an app posts late or never (a busy app, a crashed helper).
    static func reaction(event: UInt32, isTracked: Bool) -> Reaction {
        switch SkyLight.WindowEvent(rawValue: event) {
            case .move, .resize: .repaintBorder
            case .destroyed, .shown, .hidden: isTracked ? .refresh : .ignore
            case nil: .ignore
        }
    }

    static func handle(event: UInt32, windowId: UInt32) {
        switch reaction(event: event, isTracked: Window.get(byId: windowId) != nil) {
            case .repaintBorder: WindowBordersManager.shared.handleWindowMoved(windowId: windowId)
            case .refresh:
                let name = SkyLight.WindowEvent(rawValue: event).map { "\($0)" } ?? "\(event)"
                onAxWindowListChanged(notif: "ws-\(name)")
            case .ignore: break
        }
    }
}
