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
    // SLSOrderWindow(cid, window, order, relativeTo): order 1 = above, -1 = below, 0 = out
    private typealias OrderWindowFun = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
    // SLSGetWindowLevel(cid, window, &outLevel) -> error
    private typealias GetWindowLevelFun = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    // SLSGetWindowSubLevel(cid, window) -> subLevel
    private typealias GetWindowSubLevelFun = @convention(c) (Int32, UInt32) -> Int32
    // SLSSetWindow{Level,SubLevel}(cid, window, level) -> error
    private typealias SetWindowLevelFun = @convention(c) (Int32, UInt32, Int32) -> Int32

    @unsafe private struct Impl {
        let connection: Int32
        let getWindowBounds: GetWindowBoundsFun
        let orderWindow: OrderWindowFun?
        let getWindowLevel: GetWindowLevelFun?
        let getWindowSubLevel: GetWindowSubLevelFun?
        let setWindowLevel: SetWindowLevelFun?
        let setWindowSubLevel: SetWindowLevelFun?
    }

    private static let impl: Impl? = {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let mainConnectionSym = unsafe dlsym(handle, "SLSMainConnectionID"),
              let getBoundsSym = unsafe dlsym(handle, "SLSGetWindowBounds")
        else { return nil }
        let mainConnection = unsafe unsafeBitCast(mainConnectionSym, to: MainConnectionIDFun.self)
        let getWindowBounds = unsafe unsafeBitCast(getBoundsSym, to: GetWindowBoundsFun.self)
        let orderWindow = unsafe dlsym(handle, "SLSOrderWindow").map { unsafe unsafeBitCast($0, to: OrderWindowFun.self) }
        let getWindowLevel = unsafe dlsym(handle, "SLSGetWindowLevel").map { unsafe unsafeBitCast($0, to: GetWindowLevelFun.self) }
        let getWindowSubLevel = unsafe dlsym(handle, "SLSGetWindowSubLevel").map { unsafe unsafeBitCast($0, to: GetWindowSubLevelFun.self) }
        let setWindowLevel = unsafe dlsym(handle, "SLSSetWindowLevel").map { unsafe unsafeBitCast($0, to: SetWindowLevelFun.self) }
        let setWindowSubLevel = unsafe dlsym(handle, "SLSSetWindowSubLevel").map { unsafe unsafeBitCast($0, to: SetWindowLevelFun.self) }
        return unsafe Impl(connection: mainConnection(), getWindowBounds: getWindowBounds, orderWindow: orderWindow,
                           getWindowLevel: getWindowLevel, getWindowSubLevel: getWindowSubLevel,
                           setWindowLevel: setWindowLevel, setWindowSubLevel: setWindowSubLevel)
    }()

    static var isAvailable: Bool { unsafe impl != nil }

    /// Places our own overlay `window` directly above `relativeTo` and glues it into that window's
    /// stacking group by copying the target's window level AND sub-level onto the overlay. This is
    /// how JankyBorders keeps a border above its target even when the target belongs to the *active*
    /// application: a plain SLSOrderWindow is overridden by WindowServer's active-app-forward policy
    /// (our overlay is always owned by a background app), but matching level+sub-level makes the
    /// overlay ride inside the target's group so it's carried along instead of stranded below it.
    /// SIP-free because we only ever mutate a window we own (the overlay)
    @MainActor static func orderWindow(_ window: UInt32, above relativeTo: UInt32) {
        guard let impl = unsafe impl, let orderWindow = unsafe impl.orderWindow else { return }
        if let getLevel = unsafe impl.getWindowLevel, let setLevel = unsafe impl.setWindowLevel {
            var level: Int32 = 0
            _ = unsafe getLevel(impl.connection, relativeTo, &level)
            _ = unsafe setLevel(impl.connection, window, level)
        }
        if let getSub = unsafe impl.getWindowSubLevel, let setSub = unsafe impl.setWindowSubLevel {
            let subLevel = unsafe getSub(impl.connection, relativeTo)
            _ = unsafe setSub(impl.connection, window, subLevel)
        }
        _ = unsafe orderWindow(impl.connection, window, 1, relativeTo)
    }

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
        let state = signposter.beginInterval("SkyLight.windowBounds")
        defer { signposter.endInterval("SkyLight.windowBounds", state) }
        var rect = CGRect.zero
        guard unsafe impl.getWindowBounds(impl.connection, windowId, &rect) == 0 else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }
        return Rect(topLeftX: rect.origin.x, topLeftY: rect.origin.y, width: rect.width, height: rect.height)
    }
}

// Windows whose frame we've written via AX during the current refresh session. WindowServer
// (SkyLight) can lag an AX frame write, so a read-after-write in the same session (e.g. `resize`
// then `center-window`) must go through AX - which is serialized after the write on the app's
// thread - instead of the SkyLight fast path, or it reads the pre-write frame and mis-positions.
// Cleared at each session start. Guarded by Thread.isMainThread; these ops run on the main actor
private nonisolated(unsafe) var framesWrittenThisSession: Set<UInt32> = []

func markFrameWrittenThisSession(_ windowId: UInt32) {
    if Thread.isMainThread { unsafe framesWrittenThisSession.insert(windowId) }
}

@MainActor func clearFramesWrittenThisSession() {
    unsafe framesWrittenThisSession.removeAll(keepingCapacity: true)
}

/// True when SkyLight might be stale for this window (its frame was written this session). When
/// uncertain (off the main thread) returns true, so the caller falls back to the always-correct AX read
func skyLightFrameMayBeStale(_ windowId: UInt32) -> Bool {
    Thread.isMainThread ? unsafe framesWrittenThisSession.contains(windowId) : true
}
