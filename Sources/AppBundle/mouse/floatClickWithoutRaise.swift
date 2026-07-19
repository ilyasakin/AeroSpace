import AppKit
import ApplicationServices
import Common
import CoreGraphics

/// Experimental CGEventTap: interactions on exposed tiles when floats exist use
/// focus-without-raise instead of macOS raise-on-click.
///
/// Delivery strategy (critical for drag):
/// - Swallow the system `leftMouseDown` and focus the tile without raising.
/// - **Do not** redeliver via `postToPid` for the whole gesture — AppKit largely ignores
///   `postToPid` mouse-drag streams (clicks may work; drags never reach the window).
/// - On mouse-up with little movement: synthesize a **pid click** (down+up) → no raise.
/// - On movement past a small threshold: hand off to a real **HID** down/drag/up stream so the
///   window under the cursor (the exposed tile) receives a normal drag. HID may raise the tile
///   for the duration of the drag; on mouse-up we restore the float layer without stealing
///   keyboard focus back from the tile.
///
/// After we swallow system down, WindowServer often emits `mouseMoved` (not `leftMouseDragged`)
/// while the button is still physically down — we treat those as drag motion.

@MainActor private var floatClickTap: CFMachPort?
@MainActor private var floatClickRunLoopSource: CFRunLoopSource?
@MainActor private var floatClickEnabled = false

/// Active redirected press (deferred click vs HID drag handoff).
@MainActor private var floatClickStream: FloatClickStream?
/// Depth of synthetic HID posts we emit from inside the tap (re-entrancy guard).
@MainActor private var floatClickSyntheticDepth = 0

/// Marks events we synthesize so our own tap never re-intercepts them.
private let floatClickSyntheticUserData: Int64 = 0x4145_524F_0001 // AERO + 1

private struct FloatClickStream {
    var windowId: UInt32
    var pid: pid_t
    var downQuartz: CGPoint
    var lastQuartz: CGPoint
    var clickState: Int64
    var phase: Phase

    enum Phase {
        /// Swallowed system down; waiting to see click vs drag.
        case pending
        /// Handed off to HID; subsequent motion is real drag delivery.
        case hidDrag
    }
}

enum FloatClickWithoutRaisePolicy {
    /// Movement (pt) before a pending press becomes a HID drag handoff.
    static let dragThresholdPoints: CGFloat = 4

    static func shouldIntercept(
        topmostIsFloating: Bool,
        topmostIsTiling: Bool,
        workspaceHasFloats: Bool,
        isAeroSpaceWindow: Bool,
        dragInProgress: Bool,
    ) -> Bool {
        if !workspaceHasFloats { return false }
        if topmostIsFloating { return false }
        if !topmostIsTiling { return false }
        if isAeroSpaceWindow { return false }
        if dragInProgress { return false }
        return true
    }

    static func isTrackedEvent(_ type: CGEventType) -> Bool {
        switch type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved: true
            default: false
        }
    }

    /// Pure geometry: has the pointer moved enough to treat the gesture as a drag?
    static func isDrag(from: CGPoint, to: CGPoint, threshold: CGFloat = dragThresholdPoints) -> Bool {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return dx * dx + dy * dy >= threshold * threshold
    }
}

@MainActor
func syncFloatClickWithoutRaise(_ config: Config) {
    let want = config.floating.clickWithoutRaise
    if want == floatClickEnabled { return }
    if want { installFloatClickTap() } else { removeFloatClickTap() }
}

@MainActor
private func installFloatClickTap() {
    removeFloatClickTap()
    // mouseMoved is required: after we swallow down, drags often become mouseMoved.
    let mask = (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        | (1 << CGEventType.tapDisabledByUserInput.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: floatClickTapCallback,
        userInfo: nil,
    ) else {
        floatClickEnabled = false
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    floatClickTap = tap
    floatClickRunLoopSource = source
    floatClickEnabled = true
}

@MainActor
private func removeFloatClickTap() {
    endFloatClickStream(restoreFloatLayer: false)
    if let source = floatClickRunLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        floatClickRunLoopSource = nil
    }
    if let tap = floatClickTap {
        CGEvent.tapEnable(tap: tap, enable: false)
        floatClickTap = nil
    }
    floatClickEnabled = false
}

@MainActor
private func endFloatClickStream(restoreFloatLayer: Bool) {
    let windowId = floatClickStream?.windowId
    let wasHidDrag = floatClickStream?.phase == .hidDrag
    floatClickStream = nil
    if restoreFloatLayer, wasHidDrag {
        // HID drag may have raised the tile over floats. Put floats back without stealing key focus.
        let tile = windowId.flatMap { Window.get(byId: $0) }
        FloatLayer.ensureFloatsAboveTiling(focusedTile: tile)
        WindowBordersManager.shared.syncActiveFocus()
    }
}

private enum FloatClickAction {
    case passThrough
    /// Swallow event (no system delivery).
    case swallow
    /// Swallow system down; focus without raise; wait for click vs drag.
    case beginPending(windowId: UInt32, pid: pid_t, clickState: Int64)
    /// Pure click: postToPid down+up (no raise); end stream.
    case deliverPidClick(pid: pid_t, down: CGPoint, up: CGPoint, clickState: Int64)
    /// First motion past threshold: HID down at origin + HID drag at current.
    case beginHidDrag(down: CGPoint, current: CGPoint, clickState: Int64)
    /// Continue HID drag.
    case hidDragMove(at: CGPoint, clickState: Int64)
    /// End HID drag.
    case hidDragUp(at: CGPoint, clickState: Int64)
}

private let floatClickTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let tap = floatClickTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // Our own HID synthesised events must never re-enter the intercept path.
    if event.getIntegerValueField(.eventSourceUserData) == floatClickSyntheticUserData {
        return Unmanaged.passUnretained(event)
    }
    if Thread.isMainThread {
        let depth = MainActor.assumeIsolated { floatClickSyntheticDepth }
        if depth > 0 {
            return Unmanaged.passUnretained(event)
        }
    }

    guard FloatClickWithoutRaisePolicy.isTrackedEvent(type) else {
        return Unmanaged.passUnretained(event)
    }

    let quartzLocation = event.location
    // Prefer event-local button state; also track physical buttons as a fallback.
    let leftDown = (NSEvent.pressedMouseButtons & (1 << 0)) != 0
    let clickState = max(1, event.getIntegerValueField(.mouseEventClickState))

    let action: FloatClickAction = {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                evaluateFloatClickAction(
                    type: type,
                    atQuartz: quartzLocation,
                    leftButtonDown: leftDown,
                    clickState: clickState,
                )
            }
        }
        return .passThrough
    }()

    switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .beginPending(let windowId, let pid, let clickState):
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    beginFloatClickPending(windowId: windowId, pid: pid, at: quartzLocation, clickState: clickState)
                }
            }
            return nil
        case .deliverPidClick(let pid, let down, let up, let clickState):
            // Click without raise: pid-targeted down+up. Works for activation; not for drag.
            postPidMouse(to: pid, type: .leftMouseDown, at: down, clickState: clickState)
            postPidMouse(to: pid, type: .leftMouseUp, at: up, clickState: clickState)
            if Thread.isMainThread {
                MainActor.assumeIsolated { endFloatClickStream(restoreFloatLayer: false) }
            }
            return nil
        case .beginHidDrag(let down, let current, let clickState):
            // Real WindowServer delivery so AppKit / title-bar / text-drag tracking start.
            postHidMouse(type: .leftMouseDown, at: down, clickState: clickState)
            postHidMouse(type: .leftMouseDragged, at: current, clickState: clickState)
            return nil
        case .hidDragMove(let at, let clickState):
            postHidMouse(type: .leftMouseDragged, at: at, clickState: clickState)
            return nil
        case .hidDragUp(let at, let clickState):
            postHidMouse(type: .leftMouseUp, at: at, clickState: clickState)
            if Thread.isMainThread {
                MainActor.assumeIsolated { endFloatClickStream(restoreFloatLayer: true) }
            }
            return nil
    }
}

// MARK: - Event posting

private func postPidMouse(to pid: pid_t, type: CGEventType, at quartzLocation: CGPoint, clickState: Int64) {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: quartzLocation,
        mouseButton: .left,
    ) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
    event.postToPid(pid)
}

private func postHidMouse(type: CGEventType, at quartzLocation: CGPoint, clickState: Int64) {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: quartzLocation,
        mouseButton: .left,
    ) else { return }
    event.setIntegerValueField(.eventSourceUserData, value: floatClickSyntheticUserData)
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
    // Re-entrancy: head-insert tap will see this event before it reaches WindowServer.
    if Thread.isMainThread {
        MainActor.assumeIsolated { floatClickSyntheticDepth += 1 }
    }
    event.post(tap: .cghidEventTap)
    if Thread.isMainThread {
        MainActor.assumeIsolated { floatClickSyntheticDepth -= 1 }
    }
}

// MARK: - Decision

@MainActor
private func evaluateFloatClickAction(
    type: CGEventType,
    atQuartz quartzLocation: CGPoint,
    leftButtonDown: Bool,
    clickState: Int64,
) -> FloatClickAction {
    // An active stream means we swallowed the system down — treat button as down until up
    // (NSEvent.pressedMouseButtons is not always trustworthy inside the tap callback).
    if var stream = floatClickStream {
        stream.lastQuartz = quartzLocation
        stream.clickState = max(stream.clickState, clickState)

        let released = type == .leftMouseUp || (type == .mouseMoved && !leftButtonDown)
        let motion = type == .leftMouseDragged || type == .mouseMoved

        switch stream.phase {
            case .pending:
                if released {
                    let action = FloatClickAction.deliverPidClick(
                        pid: stream.pid,
                        down: stream.downQuartz,
                        up: quartzLocation,
                        clickState: stream.clickState,
                    )
                    floatClickStream = stream
                    return action
                }
                if motion {
                    let pastSlop = FloatClickWithoutRaisePolicy.isDrag(
                        from: stream.downQuartz,
                        to: quartzLocation,
                    ) || type == .leftMouseDragged
                    if pastSlop {
                        stream.phase = .hidDrag
                        floatClickStream = stream
                        return .beginHidDrag(
                            down: stream.downQuartz,
                            current: quartzLocation,
                            clickState: stream.clickState,
                        )
                    }
                    // Inside click-slop: keep pending, swallow jitter.
                    floatClickStream = stream
                    return .swallow
                }
                if type == .leftMouseDown {
                    endFloatClickStream(restoreFloatLayer: false)
                    // Fall through to treat as a fresh down.
                } else {
                    floatClickStream = stream
                    return .swallow
                }

            case .hidDrag:
                floatClickStream = stream
                if released {
                    return .hidDragUp(at: quartzLocation, clickState: stream.clickState)
                }
                if motion || leftButtonDown {
                    return .hidDragMove(at: quartzLocation, clickState: stream.clickState)
                }
                return .hidDragUp(at: quartzLocation, clickState: stream.clickState)
        }
    }

    guard type == .leftMouseDown else { return .passThrough }
    if serverArgs.isReadOnly { return .passThrough }
    if currentlyManipulatedWithMouseWindowId != nil { return .passThrough }

    let location = quartzLocation.withYAxisFlipped
    invalidateOnScreenWindowSnapshot()
    guard let top = topmostManagedWindow(at: location) else { return .passThrough }

    let workspace = top.nodeWorkspace ?? location.monitorApproximation.activeWorkspace
    let hasFloats = !workspace.floatingWindows.isEmpty
    let ok = FloatClickWithoutRaisePolicy.shouldIntercept(
        topmostIsFloating: top.isFloating,
        topmostIsTiling: !top.isFloating && top.parent is TilingContainer,
        workspaceHasFloats: hasFloats,
        isAeroSpaceWindow: top.app.pid == getpid(),
        dragInProgress: currentlyManipulatedWithMouseWindowId != nil,
    )
    if !ok { return .passThrough }
    return .beginPending(windowId: top.windowId, pid: top.app.pid, clickState: clickState)
}

@MainActor
private func beginFloatClickPending(windowId: UInt32, pid: pid_t, at quartz: CGPoint, clickState: Int64) {
    // Idempotent update while still inside click-slop (same pending stream).
    if let existing = floatClickStream, existing.phase == .pending, existing.windowId == windowId {
        return
    }
    floatClickStream = FloatClickStream(
        windowId: windowId,
        pid: pid,
        downQuartz: quartz,
        lastQuartz: quartz,
        clickState: clickState,
        phase: .pending,
    )
    guard let window = Window.get(byId: windowId) else { return }
    // Focus without raise *before* any later HID handoff (which may raise for drag).
    _ = window.focusWindow()
    window.nativeFocusRespectingFloats()
    WindowBordersManager.shared.syncActiveFocus()
    if let token: RunSessionGuard = .isServerEnabled {
        Task { @MainActor in
            try? await runLightSession(.focusFollowsMouse, token) {}
            WindowBordersManager.shared.syncActiveFocus()
        }
    }
}

/// True front-to-back hit test (click path). Not float-first like FFM hover.
@MainActor
func topmostManagedWindow(at location: CGPoint) -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace
    let stack = onScreenWindowSnapshot().normalStack
    for item in stack {
        guard item.rect.contains(location) else { continue }
        guard let window = Window.get(byId: item.id) else { continue }
        if window.isHiddenInCorner { continue }
        if window.nodeWorkspace == workspace { return window }
        if window.isSticky, window.nodeMonitor?.activeWorkspace == workspace { return window }
    }
    if let w = location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: false,
        fullscreenCoversAll: true,
    ) {
        return w
    }
    return location.findWindowRecursively(
        in: workspace.rootTilingContainer,
        virtual: true,
        fullscreenCoversAll: true,
    )
}
