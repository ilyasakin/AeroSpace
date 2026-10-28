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

    static var isObserving: Bool { tap != nil || fallbackMonitor != nil }

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
