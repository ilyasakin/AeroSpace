import AppKit
import Common

/// The one boundary to macOS.
///
/// Everything above it — kernel, model, layout, commands, UI logic — reaches macOS only through
/// this protocol (plus `WindowServerReadPort` for WindowServer reads), addressed by window id.
/// Production is `SystemMacOS`; tests install a simulator, so the same frame, focus and parking
/// logic runs in tests as on a real desktop. `MacOSPortBoundaryTest` keeps AX / SkyLight /
/// NSWorkspace calls inside `macos/`.
///
/// Reads may be slow (the app answers over AX on its own thread) and may fail (`nil`); writes are
/// fire-and-forget effects whose outcome shows up later as an observation.
@MainActor
protocol MacOSPort: AnyObject {
    // MARK: Window reads (the app's own answer, over AX)
    func axFrame(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect?
    func axTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String?
    /// `nil` = the read failed (busy app, dying window), which is not "normal"
    func nativeState(_ windowId: UInt32, _ cm: CancellationMode) async throws -> MacosNativeWindowState?

    // MARK: Window effects
    /// `onAnswer` gets the frame the app reports right after applying the write (nil: unreadable),
    /// on any thread. Not called for a write a newer one replaced before it ran.
    func writeFrame(_ windowId: UInt32, topLeft: CGPoint?, size: CGSize?, trailingSize: Bool, onAnswer: @escaping @Sendable (Rect?) -> Void)
    /// Activate the app, raise the window, make it main/key
    func focus(_ windowId: UInt32)
    /// Key focus without changing the global z-order. `false` = not possible; caller raises instead
    func focusWithoutRaise(_ windowId: UInt32, previousKeyWindowId: UInt32?) async -> Bool
    func raise(_ windowId: UInt32)
    /// Returns once the app has processed the raise
    func raiseAndWait(_ windowId: UInt32) async
    /// Press the close button. The window leaves the model when the app reports it gone
    func close(_ windowId: UInt32)
    func setNativeFullscreen(_ windowId: UInt32, _ on: Bool)
    func setNativeMinimized(_ windowId: UInt32, _ on: Bool)

    // MARK: Discovery
    /// Enumerate the running apps' windows: collect those that are gone, register new ones.
    /// (Registers into the model directly for now; stage C of step 2 turns this into observations.)
    func discoverWindows() async throws

    // MARK: Classification and apps
    /// What kind of window this is (popup / dialog / window), from its AX attributes and level
    func windowType(_ windowId: UInt32, level: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType
    /// How many windows the window's app has, per AX (nil = unknown)
    func windowCountOfApp(ofWindow windowId: UInt32) async -> Int?
    /// Ask the window's app to quit. False = it refused (or no such app)
    func quitApp(ofWindow windowId: UInt32) -> Bool
    /// The session's screen is locked (AX then shows no windows at all)
    var isScreenLocked: Bool { get }
    /// A native-fullscreen Space is showing (AX then lists hardly any other app's windows)
    var isOnFullscreenSpace: Bool { get }
    /// The model accepted `windowId` as natively focused (the next focus of it can skip AX)
    func noteObservedNativeFocus(_ windowId: UInt32)
    /// The window has an AX toolbar (Tahoe draws those with a larger corner radius)
    func windowHasToolbar(_ windowId: UInt32) async -> Bool

    // MARK: Quit path — synchronous and bounded (the process is exiting; nothing may be awaited)
    func axFrameForTermination(_ windowId: UInt32) -> Rect?
    func writeFrameForTermination(_ windowId: UInt32, topLeft: CGPoint, size: CGSize)
}

/// Process-wide install point, like `WindowServerReads`
@MainActor
enum MacOS {
    private static var installed: (any MacOSPort)?

    static var current: any MacOSPort {
        if let installed { return installed }
        // Under test nothing may reach the real desktop; tests install a simulator in setUp
        return Headless.isActive ? UnavailableMacOS.shared : SystemMacOS.shared
    }

    /// Install a simulator (tests), or `nil` to restore the default
    static func install(_ port: (any MacOSPort)?) { installed = port }
}

/// Production: AX on each app's own thread, via the registered `MacApp`
@MainActor
final class SystemMacOS: MacOSPort {
    static let shared = SystemMacOS()
    private init() {}

    private func app(of windowId: UInt32) -> MacApp? { (Window.registry[windowId] as? MacWindow)?.macApp }

    func axFrame(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await app(of: windowId)?.getAxRect(windowId, cm)
    }

    func axTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await app(of: windowId)?.getAxTitle(windowId, cm)
    }

    func nativeState(_ windowId: UInt32, _ cm: CancellationMode) async throws -> MacosNativeWindowState? {
        guard let app = app(of: windowId) else { return nil }
        // Both attributes in one thread-hop onto the app's AX thread
        let read = try await app.nativeFullscreenAndMinimized(windowId, cm)
        return macosNativeState(fullscreen: read?.fullscreen, minimized: read?.minimized)
    }

    func writeFrame(_ windowId: UInt32, topLeft: CGPoint?, size: CGSize?, trailingSize: Bool, onAnswer: @escaping @Sendable (Rect?) -> Void) {
        app(of: windowId)?.setAxFrame(windowId, topLeft, size, trailingSize: trailingSize, onAnswer: onAnswer)
    }

    func focus(_ windowId: UInt32) {
        guard let app = app(of: windowId) else { return }
        app.nativeFocus(windowId)
        PrivateFocus.noteKeyWindow(pid: app.pid, windowId: windowId)
    }

    func focusWithoutRaise(_ windowId: UInt32, previousKeyWindowId: UInt32?) async -> Bool {
        if serverArgs.isReadOnly { return true }
        guard let app = app(of: windowId) else { return false }
        let ok = await PrivateFocus.focusWithoutRaise(pid: app.pid, windowId: windowId, previousKeyWindowId: previousKeyWindowId)
        if ok { app.lastNativeFocusedWindowId = windowId }
        return ok
    }

    func raise(_ windowId: UInt32) { app(of: windowId)?.raiseWindow(windowId) }
    func raiseAndWait(_ windowId: UInt32) async { await app(of: windowId)?.raiseWindowAndWait(windowId) }

    func close(_ windowId: UInt32) {
        guard let window = (Window.registry[windowId] as? MacWindow) else { return }
        window.garbageCollect(skipClosedWindowsCache: true)
        window.macApp.closeAndUnregisterAxWindow(windowId)
    }

    func setNativeFullscreen(_ windowId: UInt32, _ on: Bool) { app(of: windowId)?.setNativeFullscreen(windowId, on) }
    func setNativeMinimized(_ windowId: UInt32, _ on: Bool) { app(of: windowId)?.setNativeMinimized(windowId, on) }

    func discoverWindows() async throws {
        let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let aliveWindowIds = mapping.values.flatMap(id).toSet()
        FrameTrace.log("discovery apps=\(mapping.count) windows=\(aliveWindowIds.count) registered=\(Window.registry.count)")

        for window in MacWindow.allWindows {
            if !aliveWindowIds.contains(window.windowId) {
                window.garbageCollect(skipClosedWindowsCache: false)
            }
        }
        for (app, windowIds) in mapping {
            for windowId in windowIds {
                try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
            }
        }
        FrameTrace.log("discovery done registered=\(Window.registry.count)")
    }

    func windowType(_ windowId: UInt32, level: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        try await app(of: windowId)?.resolveWindowType(windowId, level, cm) ?? .window
    }

    func windowCountOfApp(ofWindow windowId: UInt32) async -> Int? {
        try? await app(of: windowId)?.getAxWindowsCount(.nonCancellable)
    }

    func quitApp(ofWindow windowId: UInt32) -> Bool { app(of: windowId)?.nsApp.terminate() ?? false }

    func noteObservedNativeFocus(_ windowId: UInt32) { app(of: windowId)?.lastNativeFocusedWindowId = windowId }

    var isOnFullscreenSpace: Bool {
        monitors.contains { monitor in
            DisplayRefresh.displayId(for: monitor).map { WindowServerEvents.currentSpaceIsFullscreen($0) } ?? false
        }
    }

    var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    func windowHasToolbar(_ windowId: UInt32) async -> Bool {
        (try? await app(of: windowId)?.windowHasAxToolbar(windowId, .cancellable)) == true
    }

    func axFrameForTermination(_ windowId: UInt32) -> Rect? { app(of: windowId)?.getAxRectForTermination(windowId) }
    func writeFrameForTermination(_ windowId: UInt32, topLeft: CGPoint, size: CGSize) {
        app(of: windowId)?.setAxFrameForTermination(windowId, topLeft, size)
    }
}

/// Under XCTest without an installed simulator: every read answers "unknown", every effect is a
/// no-op — nothing can reach the developer's desktop
@MainActor
final class UnavailableMacOS: MacOSPort {
    static let shared = UnavailableMacOS()
    private init() {}
    func axFrame(_: UInt32, _: CancellationMode) async throws -> Rect? { nil }
    func axTitle(_: UInt32, _: CancellationMode) async throws -> String? { nil }
    func nativeState(_: UInt32, _: CancellationMode) async throws -> MacosNativeWindowState? { nil }
    func writeFrame(_: UInt32, topLeft _: CGPoint?, size _: CGSize?, trailingSize _: Bool, onAnswer _: @escaping @Sendable (Rect?) -> Void) {}
    func focus(_: UInt32) {}
    func focusWithoutRaise(_: UInt32, previousKeyWindowId _: UInt32?) async -> Bool { false }
    func raise(_: UInt32) {}
    func raiseAndWait(_: UInt32) async {}
    func close(_: UInt32) {}
    func setNativeFullscreen(_: UInt32, _: Bool) {}
    func setNativeMinimized(_: UInt32, _: Bool) {}
    func discoverWindows() async throws {}
    func windowType(_: UInt32, level _: MacOsWindowLevel?, _: CancellationMode) async throws -> AxUiElementWindowType { .window }
    func windowCountOfApp(ofWindow _: UInt32) async -> Int? { nil }
    func quitApp(ofWindow _: UInt32) -> Bool { false }
    func noteObservedNativeFocus(_: UInt32) {}
    var isScreenLocked: Bool { false }
    var isOnFullscreenSpace: Bool { false }
    func windowHasToolbar(_: UInt32) async -> Bool { false }
    func axFrameForTermination(_: UInt32) -> Rect? { nil }
    func writeFrameForTermination(_: UInt32, topLeft _: CGPoint, size _: CGSize) {}
}
