import Common
import Foundation

/// Every side effect that reaches OUTSIDE this process — another app, the WindowServer, the
/// user's input devices, the shell — passes through `Headless.permits` first.
///
/// Under XCTest the gate refuses and records the attempt. Tests therefore drive the real command /
/// session / layout / side-UI code paths against `TestWindow`s without being able to disturb the
/// user's desktop or a running AeroSpace instance: no global hotkeys are registered (they would
/// compete with the live instance's bindings), no panels or border windows appear on screen, no
/// processes are spawned, no sockets are bound, the cursor is never moved, and no app is activated.
///
/// `HeadlessSandboxTest` asserts the recorded attempts for every gated call site. A NEW outward call
/// site must be gated here too — nothing detects one that isn't.
enum OutwardEffect: String, CaseIterable, Sendable {
    /// Carbon global hotkey registration
    case globalHotkey
    /// Ordering an AppKit panel (status bar, tab bar, HUD) on screen
    case onScreenPanel
    /// Creating a raw SkyLight (border) window
    case skyLightWindow
    /// Subscribing to WindowServer window events
    case windowServerNotifications
    /// Launching a child process (exec-and-forget, exec-on-workspace-change, status command)
    case spawnProcess
    /// Binding a listening socket (CLI server, i3 IPC)
    case socketListener
    /// Posting synthetic input events or warping the cursor
    case synthesizeInput
    /// Activating / raising another application
    case activateApp
    /// Registering a real running app as an AX client (the gateway to every AX read and frame write)
    case accessibilityClient
    /// Observing global input (event tap / NSEvent global monitor)
    case inputEventTap
    /// Changing user-level system settings (login item, LaunchAgents)
    case systemSettings
}

enum Headless {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _blocked: [OutwardEffect: Int] = [:]

    /// True in unit tests: every outward effect is refused. Evaluated once — `isUnitTest` is an
    /// ObjC class lookup, and this is read on the hover / drag paths.
    static let isActive: Bool = isUnitTest

    /// Whether `effect` may run now. Refused (and recorded) under test.
    static func permits(_ effect: OutwardEffect) -> Bool {
        guard isActive else { return true }
        lock.lock()
        defer { lock.unlock() }
        unsafe _blocked[effect, default: 0] += 1
        return false
    }

    /// Attempts refused since the last reset (tests only).
    static var blockedAttempts: [OutwardEffect: Int] {
        lock.lock()
        defer { lock.unlock() }
        return unsafe _blocked
    }

    static func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        unsafe _blocked = [:]
    }
}
