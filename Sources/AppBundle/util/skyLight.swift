import Common
import Foundation

/// Minimal SIP-safe SkyLight (WindowServer) bindings.
///
/// Symbols are resolved at runtime via dlsym so that symbol drift across macOS versions
/// degrades gracefully to the AX code path instead of failing to launch.
/// Reads answered by WindowServer never wait on the target application, unlike AX requests
/// which stall for up to the messaging timeout when the app is busy.
///
/// Declarations follow the MIT-licensed references (koekeishiya/yabai, Hammerspoon)
enum SkyLight {
    /// Mirrors config.skyLightReads. The config is MainActor-isolated but reads happen
    /// on AX threads, hence the mirror. Updated on startup and on config reload
    nonisolated(unsafe) static var readsEnabled = false

    private typealias MainConnectionIDFun = @convention(c) () -> Int32
    private typealias GetWindowBoundsFun = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    /// WindowServer event callback: (event, data, dataLength, context). For window-modify events
    /// (move/resize) `data` points to the affected window's CGWindowID (a UInt32)
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    // SLSRegisterNotifyProc(handler, event, context) -> error
    private typealias RegisterNotifyProcFun = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

    /// WindowServer event ids (from JankyBorders' reverse-engineered set)
    enum WindowEvent: UInt32 { case move = 806, resize = 807 }

    @unsafe private struct Impl {
        let connection: Int32
        let getWindowBounds: GetWindowBoundsFun
        let registerNotifyProc: RegisterNotifyProcFun?
    }

    private static let impl: Impl? = {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let mainConnectionSym = unsafe dlsym(handle, "SLSMainConnectionID"),
              let getBoundsSym = unsafe dlsym(handle, "SLSGetWindowBounds")
        else { return nil }
        let mainConnection = unsafe unsafeBitCast(mainConnectionSym, to: MainConnectionIDFun.self)
        let getWindowBounds = unsafe unsafeBitCast(getBoundsSym, to: GetWindowBoundsFun.self)
        let registerNotifyProc = unsafe dlsym(handle, "SLSRegisterNotifyProc").map { unsafe unsafeBitCast($0, to: RegisterNotifyProcFun.self) }
        return unsafe Impl(connection: mainConnection(), getWindowBounds: getWindowBounds, registerNotifyProc: registerNotifyProc)
    }()

    /// Subscribe `proc` to window move/resize events for every window on the system, so border masks
    /// can track a live drag at the display's refresh rate instead of waiting for AeroSpace's refresh.
    /// The proc fires on the thread whose run loop was active at registration (the main thread here).
    /// Registered once for the app's lifetime; there is no clean unregister in this API
    @MainActor static func registerWindowEvents(_ proc: @escaping NotifyProc) {
        guard let impl = unsafe impl, let register = unsafe impl.registerNotifyProc else { return }
        for event in [WindowEvent.move, .resize] {
            _ = unsafe register(proc, event.rawValue, nil)
        }
    }

    static var isAvailable: Bool { unsafe impl != nil }

    /// The window's frame in global top-left screen coordinates (the same space AX frames use).
    /// nil when SkyLight reads are disabled, unavailable, or the window is unknown to WindowServer
    static func windowBounds(_ windowId: UInt32) -> Rect? {
        guard unsafe readsEnabled else { return nil }
        return unsafe rawWindowBounds(windowId)
    }

    /// Same as windowBounds but not gated on the `skylight-reads` opt-in - used by features that
    /// need the live on-screen frame regardless of that flag (e.g. window borders)
    static func overlayBounds(_ windowId: UInt32) -> Rect? {
        unsafe rawWindowBounds(windowId)
    }

    private static func rawWindowBounds(_ windowId: UInt32) -> Rect? {
        guard let impl = unsafe impl else { return nil }
        // No signposter here: borders call this on every WindowServer move event (display refresh
        // rate). AX paths keep intervals for Instruments; this path must stay bare-metal
        var rect = CGRect.zero
        guard unsafe impl.getWindowBounds(impl.connection, windowId, &rect) == 0 else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }
        return Rect(topLeftX: rect.origin.x, topLeftY: rect.origin.y, width: rect.width, height: rect.height)
    }
}

// Windows whose frame we've written via AX recently. WindowServer (SkyLight) can lag an AX
// frame write, so a read-after-write (e.g. `resize` then `center-window` in one binding, or a
// light session that schedules a complete refresh) must not trust SLSGetWindowBounds until the
// next light session starts — which clears the set. Heavy/complete refreshes intentionally do
// NOT clear, or the lag window after light→heavy would reintroduce the mis-position bug.
// Guarded by Thread.isMainThread; these ops run on the main actor
private nonisolated(unsafe) var framesWrittenThisSession: Set<UInt32> = []

func markFrameWrittenThisSession(_ windowId: UInt32) {
    if Thread.isMainThread { unsafe framesWrittenThisSession.insert(windowId) }
}

/// Call only at light-session entry. Complete/heavy refreshes keep the set so cross-session lag
/// after a command body still forces AX (or lastApplied for borders)
@MainActor func clearFramesWrittenThisSession() {
    unsafe framesWrittenThisSession.removeAll(keepingCapacity: true)
}

/// True when SkyLight might be stale for this window (its frame was written since the last light
/// session start). When uncertain (off the main thread) returns true, so the caller falls back
/// to the always-correct AX read
func skyLightFrameMayBeStale(_ windowId: UInt32) -> Bool {
    Thread.isMainThread ? unsafe framesWrittenThisSession.contains(windowId) : true
}
