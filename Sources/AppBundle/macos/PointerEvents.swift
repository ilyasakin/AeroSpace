import AppKit
import Common

/// The pointer, as an event source (hover focus) and as an effect (`move-mouse`). The listen-only
/// CGEvent tap, its NSEvent fallback and synthetic event posting all live here.
@MainActor
enum PointerEvents {
    private static var tap: CFMachPort?
    private static var tapSource: CFRunLoopSource?
    private static var fallbackMonitor: Any?
    private static var onMove: (@MainActor (HoverSample) -> Void)?

    private static var healthTimer: Timer?

    static var isObserving: Bool { tap != nil || fallbackMonitor != nil }

    enum TapHealth: Equatable { case ok, reenable, recreate }

    /// macOS can disable a tap without the disabled-event callback ever arriving (it is delivered
    /// through the same tap), or invalidate its port; hover focus then silently stops
    static func tapHealth(portIsValid: Bool, isEnabled: Bool) -> TapHealth {
        if !portIsValid { return .recreate }
        return isEnabled ? .ok : .reenable
    }

    private static func checkTapHealth() {
        guard let port = tap, let handler = onMove else { return }
        switch tapHealth(portIsValid: CFMachPortIsValid(port), isEnabled: CGEvent.tapIsEnabled(tap: port)) {
            case .ok: return
            case .reenable:
                FrameTrace.log("event-tap was disabled; re-enabled")
                CGEvent.tapEnable(tap: port, enable: true)
            case .recreate:
                FrameTrace.log("event-tap port invalidated; recreated")
                stopObserving()
                startObserving(handler)
        }
    }

    /// Deliver every pointer move to `handler`. Listen-only: events are never altered or swallowed.
    static func startObserving(_ handler: @escaping @MainActor (HoverSample) -> Void) {
        guard Headless.permits(.inputEventTap), !isObserving else { return }
        onMove = handler
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        if let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: pointerTapCallback,
            userInfo: nil,
        ) {
            tap = port
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            tapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            let timer = Timer(timeInterval: 5, repeats: true) { _ in
                Task { @MainActor in checkTapHealth() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        } else {
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
                MainActor.assumeIsolated {
                    let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
                    onMove?(HoverSample(point: mouseLocation, windowIdUnderPointer: UInt32(clamping: number)))
                }
            }
        }
    }

    static func stopObserving() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        fallbackMonitor = nil
        onMove = nil
    }

    fileprivate static func reenableTapAfterTimeout() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate static func deliver(_ sample: HoverSample) { onMove?(sample) }

    /// Move the cursor without posting an event. Re-associating right after keeps the pointer
    /// responsive: a bare warp mutes the user's mouse for a moment.
    static func warpCursor(to point: CGPoint) {
        guard Headless.permits(.synthesizeInput) else { return }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Move the cursor, tagged so hover focus can tell AeroSpace's own motion from the user's.
    /// False = the event could not be created.
    static func warp(to point: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: CGEventType.mouseMoved,
            mouseCursorPosition: point,
            mouseButton: CGMouseButton.left,
        ) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: HoverFocus.syntheticEventTag)
        // Don't carry the modifiers the user holds for the hotkey into the synthetic event
        event.flags = []
        if Headless.permits(.synthesizeInput) {
            event.post(tap: CGEventTapLocation.cghidEventTap)
        }
        return true
    }
}

private func pointerTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    _: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    // Read the event on the tap thread (the main run loop), then hand plain values to the actor
    let routed = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    let under = routed != 0 ? routed : event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
    let sample = HoverSample(
        point: event.location,
        windowIdUnderPointer: UInt32(clamping: under),
        isSynthetic: event.getIntegerValueField(.eventSourceUserData) == HoverFocus.syntheticEventTag,
    )
    MainActor.assumeIsolated {
        switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                PointerEvents.reenableTapAfterTimeout()
            case .mouseMoved:
                PointerEvents.deliver(sample)
            default: break
        }
    }
    return Unmanaged.passUnretained(event)
}
