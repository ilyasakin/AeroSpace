import AppKit
import Common

private struct MonitorImpl {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
}

extension MonitorImpl: Monitor {
    var height: CGFloat { rect.height }
    var width: CGFloat { rect.width }
}

/// Use it instead of NSScreen because it can be mocked in tests
protocol Monitor: AeroAny {
    /// The index in NSScreen.screens array. 1-based index
    var monitorAppKitNsScreenScreensId: Int { get }
    var name: String { get }
    var rect: Rect { get }
    var visibleRect: Rect { get }
    var width: CGFloat { get }
    var height: CGFloat { get }
    var isMain: Bool { get }
}

final class LazyMonitor: Monitor {
    private let screen: NSScreen
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let width: CGFloat
    let height: CGFloat
    let isMain: Bool
    private var _rect: Rect?
    private var _visibleRect: Rect?

    init(monitorAppKitNsScreenScreensId: Int, isMain: Bool, _ screen: NSScreen) {
        self.monitorAppKitNsScreenScreensId = monitorAppKitNsScreenScreensId
        self.name = screen.localizedName
        self.width = screen.frame.width // Don't call rect because it would cause recursion during mainMonitor init
        self.height = screen.frame.height // Don't call rect because it would cause recursion during mainMonitor init
        self.screen = screen
        self.isMain = isMain
    }

    var rect: Rect {
        _rect ?? screen.rect.also { _rect = $0 }
    }

    var visibleRect: Rect {
        _visibleRect ?? screen.visibleRect.also { _visibleRect = $0 }
    }
}

// Note to myself: Don't use NSScreen.main, it's garbage
// 1. The name is misleading, it's supposed to be called "focusedScreen"
// 2. It's inaccurate because NSScreen.main doesn't work correctly from NSWorkspace.didActivateApplicationNotification &
//    kAXFocusedWindowChangedNotification callbacks.
extension NSScreen {
    fileprivate func toMonitor(monitorAppKitNsScreenScreensId: Int) -> Monitor {
        MonitorImpl(
            monitorAppKitNsScreenScreensId: monitorAppKitNsScreenScreensId,
            name: localizedName,
            rect: rect,
            visibleRect: visibleRect,
            isMain: isMainScreen,
        )
    }

    fileprivate var isMainScreen: Bool {
        frame.minX == 0 && frame.minY == 0
    }

    /// The property is a replacement for Apple's crazy ``frame``
    ///
    /// - For ``MacWindow.topLeftCorner``, (0, 0) is main screen top left corner, and positive y-axis goes down.
    /// - For ``frame``, (0, 0) is main screen bottom left corner, and positive y-axis goes up (which is crazy).
    ///
    /// The property "normalizes" ``frame``
    fileprivate var rect: Rect { frame.monitorFrameNormalized() }

    /// Same as ``rect`` but for ``visibleFrame``
    fileprivate var visibleRect: Rect { visibleFrame.monitorFrameNormalized() }
}

private let testMonitorRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
private let testMonitor = MonitorImpl(
    monitorAppKitNsScreenScreensId: 1,
    name: "Test Monitor",
    rect: testMonitorRect,
    visibleRect: testMonitorRect,
    isMain: true,
)

// Guarded by Thread.isMainThread at every access (NSScreen.screens is main-thread-only anyway)
private nonisolated(unsafe) var monitorsCache: [Monitor]? = nil
private nonisolated(unsafe) var mainMonitorCache: Monitor? = nil

/// Invalidated at the start of every refresh session and on display reconfiguration, mirroring
/// windowLevelCache. Collapses the ~39 per-session `monitors` call sites (each a fresh
/// NSScreen.screens rebuild + allocations) down to one rebuild per session. Also drops
/// mainMonitorCache so coordinate flips (monitorFrameNormalized / toAppKitFrame) pick up
/// the new main screen height after reconfig
@MainActor func invalidateMonitorsCache() {
    unsafe monitorsCache = nil
    unsafe mainMonitorCache = nil
}

/// Main screen in AeroSpace's coordinate system. Cached per refresh session (with monitors).
/// Must NOT go through `monitors` when building — MonitorImpl.rect normalizes via mainMonitor.height
/// (would recurse). Built as LazyMonitor from NSScreen.screens only.
var mainMonitor: Monitor {
    if isUnitTest { return testMonitor }
    if Thread.isMainThread, let cached = unsafe mainMonitorCache {
        return cached
    }
    let screens = NSScreen.screens
    // Fallback: If main screen can't be found (e.g., during display reconfiguration),
    // return screens.first or testMonitor to avoid crash
    let screen = screens.withIndex.singleOrNil(where: \.value.isMainScreen) ?? screens.first.map { (0, $0) }
    guard let screen else { return testMonitor }
    let built = LazyMonitor(monitorAppKitNsScreenScreensId: screen.index + 1, isMain: true, screen.value)
    if Thread.isMainThread {
        unsafe mainMonitorCache = built
    }
    return built
}

var monitors: [Monitor] {
    if isUnitTest { return [testMonitor] }
    if Thread.isMainThread, let cached = unsafe monitorsCache {
        return cached
    }
    let fresh = NSScreen.screens.enumerated().map { $0.element.toMonitor(monitorAppKitNsScreenScreensId: $0.offset + 1) }
    if Thread.isMainThread {
        unsafe monitorsCache = fresh
    }
    return fresh
}

var sortedMonitors: [Monitor] {
    monitors.sortedBy([\.rect.minX, \.rect.minY])
}
