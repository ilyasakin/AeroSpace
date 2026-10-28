import AppKit
import Common
import CoreGraphics

/// WindowServer move/resize events for managed windows (SkyLight notify 806/807), plus the display
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
    static func remove(_ windowIds: [UInt32]) { SkyLight.removeNotifications(for: windowIds) }

    static func currentSpaceIsFullscreen(_ displayId: CGDirectDisplayID) -> Bool {
        SkyLight.currentSpaceIsFullscreen(displayId: displayId)
    }

    static func displayBounds(_ displayId: CGDirectDisplayID) -> CGRect { CGDisplayBounds(displayId) }

    /// Raw SkyLight border windows can be created in this process
    static var canDrawBorders: Bool { BorderSkyLight.isAvailable }
}

/// WindowServer move/resize callback (runs on the thread that registered it - the main thread).
/// `data` points to the moved window's CGWindowID.
private let windowServerEventProc: SkyLight.NotifyProc = { _, data, _, _ in
    guard let data else { return }
    let windowId = data.load(as: UInt32.self)
    if Thread.isMainThread {
        MainActor.assumeIsolated { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    } else {
        DispatchQueue.main.async { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    }
}
