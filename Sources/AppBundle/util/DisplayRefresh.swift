import AppKit
import CoreVideo
import Foundation

/// Single source of truth for **display refresh rate** and **vsync pulses**.
///
/// Policy: any animation / high-frequency work that is frame-rate bound must pace itself
/// to the refresh rate of the **screen that hosts the relevant workspace** (not a hard-coded
/// 60 Hz, and not a random display). Resolve via workspace → monitor → NSScreen → CGDisplay.
///
/// - Use `DisplayRefresh.hz(for:)` when you need the number (timers, diagnostics).
/// - Use `WorkspaceDisplayLink` when you need vsync callbacks for that display.
enum DisplayRefresh {
    static let fallbackHz: Double = 60

    // MARK: - Hz resolution

    /// Refresh rate of the screen that currently hosts `workspace`.
    @MainActor
    static func hz(for workspace: Workspace) -> Double {
        hz(for: workspace.workspaceMonitor)
    }

    /// Refresh rate of the screen for `monitor`.
    @MainActor
    static func hz(for monitor: Monitor) -> Double {
        if let screen = nsScreen(for: monitor) {
            return hz(forScreen: screen)
        }
        return fallbackHz
    }

    /// Refresh rate of the screen under `window` (workspace monitor, else frame center).
    @MainActor
    static func hz(for window: Window) -> Double {
        if let ws = window.nodeWorkspace {
            return hz(for: ws)
        }
        if let id = displayId(for: window) {
            return hz(forDisplayId: id)
        }
        return fallbackHz
    }

    static func hz(forScreen screen: NSScreen) -> Double {
        let fps = screen.maximumFramesPerSecond
        if fps > 0 { return Double(fps) }
        if let id = displayId(forScreen: screen) {
            return hzFromDisplayLinkNominal(displayId: id) ?? fallbackHz
        }
        return fallbackHz
    }

    static func hz(forDisplayId id: CGDirectDisplayID) -> Double {
        if let screen = nsScreen(forDisplayId: id) {
            let fps = screen.maximumFramesPerSecond
            if fps > 0 { return Double(fps) }
        }
        return hzFromDisplayLinkNominal(displayId: id) ?? fallbackHz
    }

    /// Frame period `1/hz` (seconds) for timer-based clients.
    @MainActor
    static func frameInterval(for workspace: Workspace) -> TimeInterval {
        let hz = max(hz(for: workspace), 1)
        return 1.0 / hz
    }

    @MainActor
    static func frameInterval(for monitor: Monitor) -> TimeInterval {
        let hz = max(hz(for: monitor), 1)
        return 1.0 / hz
    }

    // MARK: - Display / screen identity

    @MainActor
    static func displayId(for workspace: Workspace) -> CGDirectDisplayID? {
        displayId(for: workspace.workspaceMonitor)
    }

    @MainActor
    static func displayId(for monitor: Monitor) -> CGDirectDisplayID? {
        nsScreen(for: monitor).flatMap(displayId(forScreen:))
    }

    @MainActor
    static func displayId(for window: Window) -> CGDirectDisplayID? {
        if let id = window.nodeWorkspace.flatMap({ displayId(for: $0) }) {
            return id
        }
        // Fallback: geometric center of the window frame
        let rect = window.lastAppliedLayoutPhysicalRect
            ?? WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
        guard let rect else { return nil }
        let ak = rect.toAppKitFrame()
        let point = NSPoint(x: ak.midX, y: ak.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first
        return screen.flatMap(displayId(forScreen:))
    }

    static func displayId(forScreen screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    /// Prefer stable `monitorAppKitNsScreenScreensId` (1-based `NSScreen.screens` index).
    @MainActor
    static func nsScreen(for monitor: Monitor) -> NSScreen? {
        let idx = monitor.monitorAppKitNsScreenScreensId - 1
        if NSScreen.screens.indices.contains(idx) {
            return NSScreen.screens[idx]
        }
        // Geometric fallback if screens were reordered mid-session
        let akY = mainMonitor.height - (monitor.rect.topLeftY + monitor.rect.height / 2)
        let point = NSPoint(x: monitor.rect.topLeftX + monitor.rect.width / 2, y: akY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    static func nsScreen(forDisplayId id: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? CGDirectDisplayID) == id
        }
    }

    /// Prefer `NSScreen.maximumFramesPerSecond`; fall back to CVDisplayLink nominal period.
    static func nominalRefreshHz(displayLink: CVDisplayLink, screen: NSScreen?) -> Double {
        if let screen {
            let fps = screen.maximumFramesPerSecond
            if fps > 0 { return Double(fps) }
        }
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink)
        if period.timeScale != 0, period.timeValue > 0 {
            let seconds = Double(period.timeValue) / Double(period.timeScale)
            if seconds > 0 { return 1.0 / seconds }
        }
        return fallbackHz
    }

    private static func hzFromDisplayLinkNominal(displayId: CGDirectDisplayID) -> Double? {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayId, &link) == kCVReturnSuccess,
              let link
        else { return nil }
        let screen = nsScreen(forDisplayId: displayId)
        return nominalRefreshHz(displayLink: link, screen: screen)
    }
}

// MARK: - Shared vsync bus (one CVDisplayLink per CGDisplay)

/// Multiplexed display-link pulses for a given `CGDirectDisplayID`.
///
/// Multiple features (mouse-resize, future animations) can subscribe; the link starts on the
/// first subscriber and stops when the last unsubscribes. Always create links with
/// `DisplayRefresh.displayId(for: workspace)` so pacing matches the workspace’s screen.
@MainActor
enum WorkspaceDisplayLink {
    private final class LinkState {
        var link: CVDisplayLink?
        /// C callback context — owns the display id for the duration of the link.
        var context: UnsafeMutablePointer<CGDirectDisplayID>?
        var subscribers: [UUID: () -> Void] = [:]
        var hz: Double = DisplayRefresh.fallbackHz
    }

    private static var states: [CGDirectDisplayID: LinkState] = [:]

    /// Nominal Hz of an active link, or nil if nothing is subscribed on that display.
    static func activeRefreshHz(for displayId: CGDirectDisplayID) -> Double? {
        states[displayId]?.hz
    }

    /// Subscribe `onPulse` to vsync of `displayId`. Call `unsubscribe` with the same `id` to stop.
    static func subscribe(displayId: CGDirectDisplayID, id: UUID, onPulse: @escaping () -> Void) {
        let state = states[displayId] ?? LinkState()
        states[displayId] = state
        let wasEmpty = state.subscribers.isEmpty
        state.subscribers[id] = onPulse
        if wasEmpty {
            startLink(displayId: displayId, state: state)
        }
    }

    static func unsubscribe(displayId: CGDirectDisplayID, id: UUID) {
        guard let state = states[displayId] else { return }
        state.subscribers.removeValue(forKey: id)
        if state.subscribers.isEmpty {
            stopLink(state: state)
            states.removeValue(forKey: displayId)
        }
    }

    /// Move a subscription from one display to another (workspace moved monitors mid-gesture).
    static func migrate(id: UUID, from oldId: CGDirectDisplayID, to newId: CGDirectDisplayID, onPulse: @escaping () -> Void) {
        guard oldId != newId else { return }
        unsubscribe(displayId: oldId, id: id)
        subscribe(displayId: newId, id: id, onPulse: onPulse)
    }

    /// Fan-out vsync to subscribers (called from display-link C callback via main queue).
    fileprivate static func pulse(displayId: CGDirectDisplayID) {
        guard let state = states[displayId] else { return }
        for handler in state.subscribers.values {
            handler()
        }
    }

    private static func startLink(displayId: CGDirectDisplayID, state: LinkState) {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayId, &link) == kCVReturnSuccess,
              let link
        else { return }

        state.hz = DisplayRefresh.nominalRefreshHz(
            displayLink: link,
            screen: DisplayRefresh.nsScreen(forDisplayId: displayId),
        )

        // C callback cannot capture Swift context — pass display id via userInfo pointer.
        let ctx = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: 1)
        ctx.initialize(to: displayId)
        state.context = ctx

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let id = userInfo.assumingMemoryBound(to: CGDirectDisplayID.self).pointee
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WorkspaceDisplayLink.pulse(displayId: id) }
            }
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(link)
        state.link = link
    }

    private static func stopLink(state: LinkState) {
        if let link = state.link {
            CVDisplayLinkStop(link)
        }
        state.link = nil
        if let ctx = state.context {
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            state.context = nil
        }
    }
}
