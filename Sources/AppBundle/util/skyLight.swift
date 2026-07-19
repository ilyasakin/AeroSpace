import Common
import CoreGraphics
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
    // SLSRequestNotificationsForWindows(cid, window_list, window_count) -> error
    // Required for continuous move/resize delivery (JankyBorders/yabai); register alone is not enough.
    private typealias RequestNotificationsFun = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    // SLSManagedDisplayGetCurrentSpace(cid, display_uuid) -> space_id (0 on failure)
    private typealias ManagedDisplayGetCurrentSpaceFun = @convention(c) (Int32, CFString) -> UInt64
    // SLSSpaceGetType(cid, space_id) -> type (0 user, 4 native fullscreen — yabai/JankyBorders)
    private typealias SpaceGetTypeFun = @convention(c) (Int32, UInt64) -> Int32
    // CGDisplayCreateUUIDFromDisplayID — not exposed to Swift on newer SDKs; resolved at runtime
    private typealias DisplayCreateUUIDFun = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
    // SLSFindWindowAndOwner(cid, filter_wid, 1, 0, &screen_point, &window_point, &wid, &wcid)
    // WindowServer's event-routing hit test (yabai) — honors ignores-mouse-events + all levels
    private typealias FindWindowAndOwnerFun = @convention(c) (
        Int32, Int32, Int32, Int32,
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>,
    ) -> Int32

    private static let displayCreateUUID: DisplayCreateUUIDFun? = {
        // macOS 26 dropped the symbol from CoreGraphics; it still lives in ColorSync
        for path in [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/Frameworks/ColorSync.framework/ColorSync",
        ] {
            guard let handle = unsafe dlopen(path, RTLD_LAZY) else { continue }
            if let sym = unsafe dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") {
                return unsafe unsafeBitCast(sym, to: DisplayCreateUUIDFun.self)
            }
        }
        return nil
    }()

    /// WindowServer event ids (from JankyBorders' reverse-engineered set)
    enum WindowEvent: UInt32 { case move = 806, resize = 807 }

    @unsafe private struct Impl {
        let connection: Int32
        let getWindowBounds: GetWindowBoundsFun
        let registerNotifyProc: RegisterNotifyProcFun?
        let requestNotifications: RequestNotificationsFun?
        let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpaceFun?
        let spaceGetType: SpaceGetTypeFun?
        let findWindowAndOwner: FindWindowAndOwnerFun?
    }

    private static let impl: Impl? = {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let mainConnectionSym = unsafe dlsym(handle, "SLSMainConnectionID"),
              let getBoundsSym = unsafe dlsym(handle, "SLSGetWindowBounds")
        else { return nil }
        let mainConnection = unsafe unsafeBitCast(mainConnectionSym, to: MainConnectionIDFun.self)
        let getWindowBounds = unsafe unsafeBitCast(getBoundsSym, to: GetWindowBoundsFun.self)
        let registerNotifyProc = unsafe dlsym(handle, "SLSRegisterNotifyProc").map { unsafe unsafeBitCast($0, to: RegisterNotifyProcFun.self) }
        let requestNotifications = unsafe dlsym(handle, "SLSRequestNotificationsForWindows").map {
            unsafe unsafeBitCast($0, to: RequestNotificationsFun.self)
        }
        let managedDisplayGetCurrentSpace = unsafe dlsym(handle, "SLSManagedDisplayGetCurrentSpace").map {
            unsafe unsafeBitCast($0, to: ManagedDisplayGetCurrentSpaceFun.self)
        }
        let spaceGetType = unsafe dlsym(handle, "SLSSpaceGetType").map {
            unsafe unsafeBitCast($0, to: SpaceGetTypeFun.self)
        }
        let findWindowAndOwner = unsafe dlsym(handle, "SLSFindWindowAndOwner").map {
            unsafe unsafeBitCast($0, to: FindWindowAndOwnerFun.self)
        }
        return unsafe Impl(
            connection: mainConnection(),
            getWindowBounds: getWindowBounds,
            registerNotifyProc: registerNotifyProc,
            requestNotifications: requestNotifications,
            managedDisplayGetCurrentSpace: managedDisplayGetCurrentSpace,
            spaceGetType: spaceGetType,
            findWindowAndOwner: findWindowAndOwner,
        )
    }()

    /// WindowServer's event-routing hit test: the window that would receive a click at `point`
    /// (Quartz global coords, y-down). Unlike CGWindowList reconstruction, this honors
    /// ignores-mouse-events overlays, elevated window levels (menus, panels), and true z-order —
    /// verified: a point covered by our click-through border overlay resolves to the window
    /// beneath it. nil when the symbol is unavailable or the lookup fails.
    static func findEventTargetWindow(at point: CGPoint) -> UInt32? {
        guard let impl = unsafe impl, let find = unsafe impl.findWindowAndOwner else { return nil }
        var screenPoint = point
        var windowPoint = CGPoint.zero
        var wid: UInt32 = 0
        var ownerConnection: Int32 = 0
        guard unsafe find(impl.connection, 0, 1, 0, &screenPoint, &windowPoint, &wid, &ownerConnection) == 0,
              wid != 0
        else { return nil }
        return wid
    }

    /// True when the display's active Space is a native macOS fullscreen Space (type 4).
    /// Overlays (borders / tab bars) describe the underlying workspace and must not paint over a
    /// fullscreen app — collectionBehavior alone does not keep canJoinAllSpaces panels off
    /// fullscreen Spaces, so callers hide their content based on this check (JankyBorders parity).
    /// Symbol drift or a failed lookup degrades to `false` (overlays stay visible).
    static func currentSpaceIsFullscreen(displayId: CGDirectDisplayID) -> Bool {
        guard let impl = unsafe impl,
              let getSpace = unsafe impl.managedDisplayGetCurrentSpace,
              let getType = unsafe impl.spaceGetType,
              let createUUID = unsafe displayCreateUUID,
              let uuid = unsafe createUUID(displayId)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid)
        else { return false }
        let space = unsafe getSpace(impl.connection, uuidString)
        guard space != 0 else { return false }
        return unsafe getType(impl.connection, space) == 4
    }

    /// Subscribe `proc` to window move/resize events. Pair with `requestNotifications(for:)` so
    /// WindowServer actually delivers continuous move/resize for the tracked window ids
    /// (register alone does not guarantee drag-rate events — see JankyBorders).
    /// The proc fires on the thread whose run loop was active at registration (the main thread here).
    /// Registered once for the app's lifetime; there is no clean unregister in this API
    @MainActor static func registerWindowEvents(_ proc: @escaping NotifyProc) {
        guard let impl = unsafe impl, let register = unsafe impl.registerNotifyProc else { return }
        for event in [WindowEvent.move, .resize] {
            _ = unsafe register(proc, event.rawValue, nil)
        }
    }

    /// Ask WindowServer to deliver modify events for these window ids to our connection.
    /// Call whenever the bordered / on-screen set changes. Empty list is a no-op.
    @MainActor static func requestNotifications(for windowIds: [UInt32]) {
        guard let impl = unsafe impl, let request = unsafe impl.requestNotifications else { return }
        guard !windowIds.isEmpty else { return }
        var ids = windowIds
        ids.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = unsafe request(impl.connection, base, Int32(buf.count))
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
