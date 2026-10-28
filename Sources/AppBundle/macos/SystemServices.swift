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

    /// The `skylight-reads` config flag: whether frame reads may use WindowServer instead of AX
    static func setWindowServerReadsEnabled(_ enabled: Bool) {
        unsafe SkyLight.readsEnabled = enabled
    }

    /// Apps AeroSpace is tracking
    static var trackedApps: [any AbstractApp] { Array(MacApp.allAppsMap.values) }

    nonisolated static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    nonisolated static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    nonisolated static func applicationToOpen(_ file: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: file) }

    /// The app's Dock icon
    static func icon(of app: any AbstractApp) -> NSImage? {
        if let mac = app as? MacApp, let icon = mac.nsApp.icon { return icon }
        return app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
    }
}
