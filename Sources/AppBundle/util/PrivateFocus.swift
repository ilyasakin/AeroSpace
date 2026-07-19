import AppKit
import Foundation

/// SIP-safe private focus (no Dock scripting addition).
/// yabai-style focus-without-raise: keyboard focus without changing global z-order.
enum PrivateFocus {
    static var isAvailable: Bool { impl != nil }

    nonisolated(unsafe) private static var lastFocusedPsn: ProcessSerialNumberBits?
    nonisolated(unsafe) private static var lastFocusedWindowId: UInt32?
    nonisolated(unsafe) static var sleepMicroseconds: (useconds_t) -> Void = { usleep($0) }
    nonisolated(unsafe) static var onPostEvent: (([UInt8]) -> Void)?

    static func resetFocusTrackingForTests() {
        unsafe lastFocusedPsn = nil
        unsafe lastFocusedWindowId = nil
    }

    static func clearLastFocusedWindowIdForTests() {
        unsafe lastFocusedWindowId = nil
    }

    /// Seed tracking after raise:true / AX focus so same-app 0x0d dance still works later.
    @discardableResult
    static func noteKeyWindow(pid: pid_t, windowId: UInt32) -> Bool {
        guard let impl else { return false }
        var psn = ProcessSerialNumberBits()
        let st = withUnsafeMutableBytes(of: &psn) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return impl.getProcessForPID(pid, base)
        }
        guard st == 0 else { return false }
        unsafe lastFocusedPsn = psn
        unsafe lastFocusedWindowId = windowId
        return true
    }

    @discardableResult
    static func focusWithoutRaise(
        pid: pid_t,
        windowId: UInt32,
        fallbackPreviousKeyWindowId: UInt32? = nil,
    ) -> Bool {
        guard let impl else { return false }
        var psn = ProcessSerialNumberBits()
        let st = withUnsafeMutableBytes(of: &psn) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return impl.getProcessForPID(pid, base)
        }
        guard st == 0 else { return false }

        let frontPsn: ProcessSerialNumberBits? = {
            guard let getFront = impl.getFrontProcess else { return nil }
            var front = ProcessSerialNumberBits()
            let code = withUnsafeMutableBytes(of: &front) { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return getFront(base)
            }
            return code == 0 ? front : nil
        }()

        let sameApp = psnEquals(psn, unsafe lastFocusedPsn) || psnEquals(psn, frontPsn)
        if sameApp {
            let fromId = unsafe lastFocusedWindowId ?? fallbackPreviousKeyWindowId
            if let fromId, fromId != windowId {
                postSameAppKeySwitch(psn: psn, fromWindowId: fromId, toWindowId: windowId, postEvent: impl.postEvent)
            }
        }

        let kCPSUserGenerated: UInt32 = 0x200
        _ = withUnsafeBytes(of: psn) { raw in
            impl.setFrontProcess(raw.baseAddress!, windowId, kCPSUserGenerated)
        }
        makeKeyWindow(psn: psn, windowId: windowId, postEvent: impl.postEvent)
        unsafe lastFocusedPsn = psn
        unsafe lastFocusedWindowId = windowId
        return true
    }

    static func sameAppSwitchEventBytes(fromWindowId: UInt32, toWindowId: UInt32, phase: SameAppPhase) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        switch phase {
            case .unfocusPrevious:
                bytes[0x8a] = 0x02
                writeWindowId(&bytes, fromWindowId)
            case .focusNext:
                bytes[0x8a] = 0x01
                writeWindowId(&bytes, toWindowId)
        }
        return bytes
    }

    enum SameAppPhase: Sendable {
        case unfocusPrevious
        case focusNext
    }

    struct ProcessSerialNumberBits: Equatable {
        var highLongOfPSN: UInt32 = 0
        var lowLongOfPSN: UInt32 = 0
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
        guard let sky = unsafe dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY,
        ) else { return nil }
        let hiServices = unsafe dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY,
        )
        let hiAppServices = unsafe dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY,
        )
        guard let hi = hiServices ?? hiAppServices else { return nil }
        guard let getSym = unsafe dlsym(hi, "GetProcessForPID"),
              let setSym = unsafe dlsym(sky, "_SLPSSetFrontProcessWithOptions"),
              let postSym = unsafe dlsym(sky, "SLPSPostEventRecordTo")
        else { return nil }
        let frontSym = unsafe dlsym(sky, "_SLPSGetFrontProcess")
        return unsafe Impl(
            getProcessForPID: unsafeBitCast(getSym, to: GetProcessForPIDFun.self),
            getFrontProcess: frontSym.map { unsafeBitCast($0, to: GetFrontProcessFun.self) },
            setFrontProcess: unsafeBitCast(setSym, to: SetFrontProcessFun.self),
            postEvent: unsafeBitCast(postSym, to: PostEventFun.self),
        )
    }()

    private static func psnEquals(_ a: ProcessSerialNumberBits, _ b: ProcessSerialNumberBits?) -> Bool {
        guard let b else { return false }
        return a.highLongOfPSN == b.highLongOfPSN && a.lowLongOfPSN == b.lowLongOfPSN
    }

    private static func writeWindowId(_ bytes: inout [UInt8], _ windowId: UInt32) {
        withUnsafeBytes(of: windowId.littleEndian) { raw in
            for i in 0 ..< 4 { bytes[0x3c + i] = raw[i] }
        }
    }

    private static func postEventBytes(_ bytes: [UInt8], psn: ProcessSerialNumberBits, postEvent: PostEventFun) {
        onPostEvent?(bytes)
        var mutable = bytes
        withUnsafeBytes(of: psn) { psnRaw in
            mutable.withUnsafeBytes { eventRaw in
                _ = postEvent(psnRaw.baseAddress!, eventRaw.baseAddress!)
            }
        }
    }

    private static func postSameAppKeySwitch(
        psn: ProcessSerialNumberBits,
        fromWindowId: UInt32,
        toWindowId: UInt32,
        postEvent: PostEventFun,
    ) {
        postEventBytes(
            sameAppSwitchEventBytes(fromWindowId: fromWindowId, toWindowId: toWindowId, phase: .unfocusPrevious),
            psn: psn,
            postEvent: postEvent,
        )
        sleepMicroseconds(40_000)
        postEventBytes(
            sameAppSwitchEventBytes(fromWindowId: fromWindowId, toWindowId: toWindowId, phase: .focusNext),
            psn: psn,
            postEvent: postEvent,
        )
    }

    private static func makeKeyWindow(psn: ProcessSerialNumberBits, windowId: UInt32, postEvent: PostEventFun) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        writeWindowId(&bytes, windowId)
        for i in 0x20 ..< 0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        postEventBytes(bytes, psn: psn, postEvent: postEvent)
        bytes[0x08] = 0x02
        postEventBytes(bytes, psn: psn, postEvent: postEvent)
    }
}

// MARK: - Float focus policy

enum FloatLayerPolicy: Equatable, Sendable {
    static func shouldRaiseOnFocus(isFloating: Bool, workspaceHasFloats: Bool) -> Bool {
        isFloating || !workspaceHasFloats
    }

    static func preferFocusWithoutRaise(isFloating: Bool, workspaceHasFloats: Bool) -> Bool {
        !isFloating && workspaceHasFloats
    }
}

@MainActor
protocol FloatLayerPort: AnyObject {
    func focusWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool
    func raiseWindow(windowId: UInt32)
}

enum FloatLayer {
    /// Test double; production uses PrivateFocus + nativeRaise.
    @MainActor static var port: (any FloatLayerPort)? = nil

    @MainActor
    private static var effectivePort: any FloatLayerPort {
        port ?? ProductionFloatLayerPort.shared
    }

    @MainActor
    static func focus(_ window: Window, raise: Bool) {
        if serverArgs.isReadOnly { return }
        if raise {
            window.nativeFocus(raise: true)
            return
        }
        let pid = window.app.pid
        if effectivePort.focusWithoutRaise(pid: pid, windowId: window.windowId) {
            (window.app as? MacApp)?.lastNativeFocusedWindowId = window.windowId
            return
        }
        window.nativeFocus(raise: false)
    }

    /// After float toggle: place the new float above the tiling stack once.
    @MainActor
    static func didBecomeFloating(_ window: Window) {
        effectivePort.raiseWindow(windowId: window.windowId)
    }

    /// Explicit recovery only (`raise-floating` / manual).
    @MainActor
    static func ensureFloatsAboveTiling(focusedTile: Window?) {
        let workspaces = Workspace.allUnsorted.filter(\.isVisible)
        for workspace in workspaces {
            let floats = workspace.floatingWindowsContainer.mruChildren.compactMap { $0 as? Window }
            for w in floats.reversed() {
                effectivePort.raiseWindow(windowId: w.windowId)
            }
        }
        if let focusedTile, !focusedTile.isFloating {
            FloatLayer.focus(focusedTile, raise: false)
        }
    }
}

@MainActor
private final class ProductionFloatLayerPort: FloatLayerPort {
    static let shared = ProductionFloatLayerPort()

    func focusWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool {
        let fallback = Window.get(byId: windowId).flatMap { ($0.app as? MacApp)?.lastNativeFocusedWindowId }
        return PrivateFocus.focusWithoutRaise(
            pid: pid,
            windowId: windowId,
            fallbackPreviousKeyWindowId: fallback,
        )
    }

    func raiseWindow(windowId: UInt32) {
        Window.get(byId: windowId)?.nativeRaise()
    }
}
