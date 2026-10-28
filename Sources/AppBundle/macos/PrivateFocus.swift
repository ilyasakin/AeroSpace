import AppKit
import Foundation

/// Focus a window for keyboard input WITHOUT changing the global z-order (yabai-style, SIP-safe):
/// `_SLPSSetFrontProcessWithOptions` + SkyLight "make key window" event records, and for a switch
/// between two windows of the same app the 0x0D unfocus → focus pair.
///
/// Used only by focus-follows-mouse (`focus-follows-mouse.raise = false`): hovering a tile that a
/// floating window overlaps must not raise the tile over the float (i3 floats stay above tiles).
/// This is NOT the old float layer — nothing re-asserts any stacking; a window simply is not
/// raised when the pointer enters it. Everything else (keyboard focus, clicks) raises natively.
///
/// Restored from this fork's own implementation (git 4eff1114^), trimmed to the no-raise path.
enum PrivateFocus {
    static var isAvailable: Bool { unsafe impl != nil }

    nonisolated(unsafe) private static var lastFocusedPsn: ProcessSerialNumberBits?
    nonisolated(unsafe) private static var lastFocusedWindowId: UInt32?
    /// Test hook: every event record posted
    nonisolated(unsafe) static var onPostEvent: (([UInt8]) -> Void)?
    nonisolated(unsafe) static var asyncSleepNanoseconds: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    /// Gap between the same-app unfocus/focus records (yabai)
    static let sameAppSwitchGapMicroseconds: UInt64 = 40000

    @MainActor private static var generation: UInt64 = 0

    /// Returns false when the private API is unavailable or refused (caller falls back to raise).
    /// The same-app gap is an async sleep, never a `usleep` on the main thread; a newer focus that
    /// starts mid-gap supersedes this one.
    @discardableResult
    @MainActor
    static func focusWithoutRaise(pid: pid_t, windowId: UInt32, previousKeyWindowId: UInt32?) async -> Bool {
        guard Headless.permits(.activateApp), let impl = unsafe impl else { return false }
        var psn = ProcessSerialNumberBits()
        let st = unsafe withUnsafeMutableBytes(of: &psn) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return unsafe impl.getProcessForPID(pid, base)
        }
        guard st == 0 else { return false }
        let frontPsn: ProcessSerialNumberBits? = unsafe impl.getFrontProcess.flatMap { getFront in
            var front = ProcessSerialNumberBits()
            let code = unsafe withUnsafeMutableBytes(of: &front) { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return unsafe getFront(base)
            }
            return code == 0 ? front : nil
        }
        let sameApp = unsafe psn == lastFocusedPsn || psn == frontPsn
        generation &+= 1
        let myGeneration = generation
        // The caller's previous window (same app, from the tree) beats the global record
        let tracked = unsafe lastFocusedWindowId
        if sameApp, let fromId = previousKeyWindowId ?? tracked, fromId != windowId {
            post(sameAppSwitchEventBytes(windowId: fromId, phase: .unfocusPrevious), psn, impl)
            await asyncSleepNanoseconds(sameAppSwitchGapMicroseconds * 1000)
            if myGeneration != generation || Task.isCancelled { return false }
            post(sameAppSwitchEventBytes(windowId: windowId, phase: .focusNext), psn, impl)
        }
        if myGeneration != generation || Task.isCancelled { return false }
        let kCPSUserGenerated: UInt32 = 0x200
        _ = unsafe withUnsafeBytes(of: psn) { raw in
            unsafe impl.setFrontProcess(raw.baseAddress!, windowId, kCPSUserGenerated)
        }
        makeKeyWindow(windowId, psn, impl)
        unsafe lastFocusedPsn = psn
        unsafe lastFocusedWindowId = windowId
        return true
    }

    /// Record which window macOS made key through a regular (raising) focus, so the next
    /// same-app no-raise switch unfocuses the right one
    static func noteKeyWindow(pid: pid_t, windowId: UInt32) {
        guard let impl = unsafe impl else { return }
        var psn = ProcessSerialNumberBits()
        let st = unsafe withUnsafeMutableBytes(of: &psn) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return unsafe impl.getProcessForPID(pid, base)
        }
        guard st == 0 else { return }
        unsafe lastFocusedPsn = psn
        unsafe lastFocusedWindowId = windowId
    }

    enum SameAppPhase: Sendable {
        case unfocusPrevious
        case focusNext
    }

    static func sameAppSwitchEventBytes(windowId: UInt32, phase: SameAppPhase) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = 0x0D
        bytes[0x8A] = phase == .unfocusPrevious ? 0x02 : 0x01
        writeWindowId(&bytes, windowId)
        return bytes
    }

    static func makeKeyWindowEventBytes(windowId: UInt32, phase: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = phase // 0x01 down, 0x02 up
        bytes[0x3A] = 0x10
        for i in 0x20 ..< 0x30 { bytes[i] = 0xFF }
        writeWindowId(&bytes, windowId)
        return bytes
    }

    struct ProcessSerialNumberBits: Equatable {
        var highLongOfPSN: UInt32 = 0
        var lowLongOfPSN: UInt32 = 0
    }

    private static func makeKeyWindow(_ windowId: UInt32, _ psn: ProcessSerialNumberBits, _ impl: Impl) {
        post(makeKeyWindowEventBytes(windowId: windowId, phase: 0x01), psn, impl)
        post(makeKeyWindowEventBytes(windowId: windowId, phase: 0x02), psn, impl)
    }

    private static func writeWindowId(_ bytes: inout [UInt8], _ windowId: UInt32) {
        unsafe withUnsafeBytes(of: windowId.littleEndian) { raw in
            for i in 0 ..< 4 { bytes[0x3C + i] = raw[i] }
        }
    }

    private static func post(_ bytes: [UInt8], _ psn: ProcessSerialNumberBits, _ impl: Impl) {
        unsafe onPostEvent?(bytes)
        var mutable = bytes
        unsafe withUnsafeBytes(of: psn) { psnRaw in
            unsafe mutable.withUnsafeBytes { eventRaw in
                _ = unsafe impl.postEvent(psnRaw.baseAddress!, eventRaw.baseAddress!)
            }
        }
    }

    private typealias GetProcessForPIDFun = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias GetFrontProcessFun = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias SetFrontProcessFun = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEventFun = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32

    private struct Impl {
        let getProcessForPID: GetProcessForPIDFun
        let getFrontProcess: GetFrontProcessFun?
        let setFrontProcess: SetFrontProcessFun
        let postEvent: PostEventFun
    }

    private static let impl: Impl? = {
        guard let sky = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        else { return nil }
        let hiServices = unsafe dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY,
        )
        let hiAppServices = unsafe dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        guard let hi = unsafe hiServices ?? hiAppServices,
              let getSym = unsafe dlsym(hi, "GetProcessForPID"),
              let setSym = unsafe dlsym(sky, "_SLPSSetFrontProcessWithOptions"),
              let postSym = unsafe dlsym(sky, "SLPSPostEventRecordTo")
        else { return nil }
        let frontSym = unsafe dlsym(sky, "_SLPSGetFrontProcess")
        return unsafe Impl(
            getProcessForPID: unsafeBitCast(getSym, to: GetProcessForPIDFun.self),
            getFrontProcess: frontSym.map { unsafe unsafeBitCast($0, to: GetFrontProcessFun.self) },
            setFrontProcess: unsafeBitCast(setSym, to: SetFrontProcessFun.self),
            postEvent: unsafeBitCast(postSym, to: PostEventFun.self),
        )
    }()
}
