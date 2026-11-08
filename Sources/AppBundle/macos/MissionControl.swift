import AppKit
import CoreGraphics
import Foundation

/// Whether Mission Control is showing. macOS 27 sends no notification for it (the Dock's Exposé
/// notifications are gone; WindowManager.app draws it now), but while it is open WindowManager
/// keeps a display-covering shield window at layer 19 ("ExposeShieldWindow", verified on 27.2).
/// Borders are separate windows that Mission Control does not shrink with their targets, so they
/// are hidden while it shows.
@MainActor
enum MissionControl {
    private(set) static var isShowing = false
    private static var timer: Timer?
    /// Test hook: replaces the WindowServer read
    static var readOverlayForTests: (() -> Bool)?

    /// WindowManager's Mission Control shield: owned by WindowManager, layer 19, covering a display
    static func isShield(ownerName: String?, layer: Int, width: Double, height: Double) -> Bool {
        ownerName == "WindowManager" && layer == 19 && width >= 200 && height >= 200
    }

    static func scanForShield(_ windows: [[String: Any]]) -> Bool {
        windows.contains { w in
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return isShield(
                ownerName: w[kCGWindowOwnerName as String] as? String,
                layer: (w[kCGWindowLayer as String] as? Int) ?? 0,
                width: (b["Width"] as? Double) ?? 0,
                height: (b["Height"] as? Double) ?? 0,
            )
        }
    }

    /// Re-read the state; true when it changed
    @discardableResult
    static func poll() -> Bool {
        let now = readOverlayForTests?() ?? scanForShield(
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [],
        )
        guard now != isShowing else { return false }
        isShowing = now
        FrameTrace.log("mission-control \(now ? "shown" : "hidden")")
        return true
    }

    /// Poll a few times a second while something on screen depends on it (about 0.5 ms per read)
    static func startWatching(onChange: @escaping @MainActor () -> Void) {
        guard timer == nil, readOverlayForTests == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in if poll() { onChange() } }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func stopWatching() {
        timer?.invalidate()
        timer = nil
        isShowing = false
    }

    static func resetForTests() {
        stopWatching()
        readOverlayForTests = nil
    }
}
