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

    @unsafe private struct Impl {
        let connection: Int32
        let getWindowBounds: GetWindowBoundsFun
    }

    private static let impl: Impl? = {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let mainConnectionSym = unsafe dlsym(handle, "SLSMainConnectionID"),
              let getBoundsSym = unsafe dlsym(handle, "SLSGetWindowBounds")
        else { return nil }
        let mainConnection = unsafe unsafeBitCast(mainConnectionSym, to: MainConnectionIDFun.self)
        let getWindowBounds = unsafe unsafeBitCast(getBoundsSym, to: GetWindowBoundsFun.self)
        return unsafe Impl(connection: mainConnection(), getWindowBounds: getWindowBounds)
    }()

    static var isAvailable: Bool { unsafe impl != nil }

    /// The window's frame in global top-left screen coordinates (the same space AX frames use).
    /// nil when SkyLight reads are disabled, unavailable, or the window is unknown to WindowServer
    static func windowBounds(_ windowId: UInt32) -> Rect? {
        guard unsafe readsEnabled, let impl = unsafe impl else { return nil }
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
