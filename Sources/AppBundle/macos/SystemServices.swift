import AppKit
import Common

/// Small system services above the window level: process-wide AX configuration, the app list,
/// opening URLs and files, app icons.
@MainActor
enum SystemServices {
    /// The default AX messaging timeout is ~6 seconds. An app that is busy and doesn't service its
    /// event loop would stall every AX request (and thus every refresh session) for that long.
    /// Setting it on the system-wide element changes the default for all AX requests of this process.
    static func configureAccessibilityClient() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)
    }

    /// Process-wide input and scheduling settings for a latency-bound window manager.
    /// - After a cursor warp macOS mutes local mouse events for 0.25 s, so the pointer freezes after
    ///   every `move-mouse`/mouse-warping warp. Interval 0 on the session source drops that freeze
    ///   (see also `PointerEvents.warpCursor`).
    /// - App Nap throttles timers of a background-only app; a window manager is never "idle".
    /// Returns which settings were applied, for tests.
    @discardableResult
    static func configureInputLatency() -> [String] {
        var applied: [String] = []
        if Headless.permits(.synthesizeInput) {
            CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
            applied.append("eventSuppression")
        }
        if Headless.permits(.systemSettings) {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Window manager reacts to input and window events",
            )
            applied.append("appNap")
        }
        return applied
    }
    private static var appNapActivity: (any NSObjectProtocol)?

    /// The `skylight-reads` config flag: whether frame reads may use WindowServer instead of AX
    static func setWindowServerReadsEnabled(_ enabled: Bool) {
        unsafe SkyLight.readsEnabled = enabled
    }

    /// Apps AeroSpace is tracking
    static var trackedApps: [any AbstractApp] { Array(MacApp.allAppsMap.values) }

    nonisolated static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// The app in front now, to give focus back after AeroSpace's own panel took it
    static func frontmostAppPid() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func activateApp(pid: pid_t) {
        guard Headless.permits(.activateApp) else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
    nonisolated static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    nonisolated static func applicationToOpen(_ file: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: file) }

    /// The app's Dock icon
    static func icon(of app: any AbstractApp) -> NSImage? {
        if let mac = app as? MacApp, let icon = mac.nsApp.icon { return icon }
        return app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
    }
}
