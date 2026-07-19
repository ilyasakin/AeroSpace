import AppKit
import ApplicationServices
import Common
import CoreGraphics

/// Experimental CGEventTap: exposed-tile clicks while floats exist use focus-without-raise.
///
/// Z-order vs key (both required for i3-like floats):
/// 1. Give the tile **keyboard** focus without raise (`PrivateFocus` / make-key).
/// 2. Put floats **on top last** (`AXRaise`, *awaited*), then transfer key back to the tile
///    with the same-app 0x0d dance. Never call `_SLPSSetFrontProcessWithOptions` after the
///    raise — it restacks the tile above C.
///
/// - mouseDown: tree focus + key without raise + pid mouseDown
/// - mouseUp: pid mouseUp → schedule the settle pipeline (single task per gesture)
/// - drag past threshold: HID stream; same settle on up
///
/// The settle must be one strictly ordered async pipeline. The previous design had two racy
/// flaws that produced "keyboard stays on C" / "C not on top":
/// - `AXRaise` went through fire-and-forget `withWindowAsync`, so the follow-up `makeKeyOnly`
///   reached the app *before* the raise; the raise then stole key back to the float.
/// - A mouseDown 40ms reinforce Task and the mouseUp restore both ran, interleaving raises
///   and make-keys — the final state depended on which landed last.

@MainActor private var floatClickTap: CFMachPort?
@MainActor private var floatClickRunLoopSource: CFRunLoopSource?
@MainActor private var floatClickEnabled = false

@MainActor private var floatClickStream: FloatClickStream?
@MainActor private var floatClickSyntheticDepth = 0
@MainActor private var floatClickSettleTask: Task<Void, Never>?

private let floatClickSyntheticUserData: Int64 = 0x4145_524F_0001

private struct FloatClickStream {
    var windowId: UInt32
    var pid: pid_t
    var downQuartz: CGPoint
    var lastQuartz: CGPoint
    var clickState: Int64
    var phase: Phase
    var pidDownPosted: Bool
    /// OS/tree key before this gesture (often the float) — used to force same-app key transfer
    /// and to re-assert after AXRaise on floats steals key back.
    var previousKeyWindowId: UInt32?

    enum Phase {
        case pending
        case hidDrag
    }
}

enum FloatClickWithoutRaisePolicy {
    /// Real movement only — small jitter during A↔B clicks must not HID-raise the tile.
    static let dragThresholdPoints: CGFloat = 12

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
    cancelFloatLayerSettle()
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
    let wasHid = floatClickStream?.phase == .hidDrag
    floatClickStream = nil
    if restoreFloatLayer, wasHid, let windowId {
        // HID raised the tile — floats last, then key transfer (no setFrontProcess restack).
        scheduleFloatLayerSettle(tileWindowId: windowId)
    }
}

/// One settle per gesture — cancel-and-replace so raises and make-keys never interleave.
@MainActor
func scheduleFloatLayerSettle(tileWindowId: UInt32) {
    floatClickSettleTask?.cancel()
    floatClickSettleTask = Task { @MainActor in
        await settleFloatLayerKeepingTileKey(tileWindowId: tileWindowId)
    }
}

@MainActor
private func cancelFloatLayerSettle() {
    floatClickSettleTask?.cancel()
    floatClickSettleTask = nil
}

/// Test seam for the key-transfer step (production: PrivateFocus, unreachable pid in tests).
@MainActor var floatClickKeyTransfer: (pid_t, UInt32, UInt32?) async -> Void = defaultFloatClickKeyTransfer

@MainActor let defaultFloatClickKeyTransfer: (pid_t, UInt32, UInt32?) async -> Void = { pid, toWindowId, fromSameAppWindowId in
    _ = await PrivateFocus.transferKeyAfterFloatRaise(
        pid: pid,
        toWindowId: toWindowId,
        fromSameAppWindowId: fromSameAppWindowId,
    )
}

/// Floats on top **last** and *awaited*, then key back to the tile.
///
/// `AXRaise` on a float of the frontmost (= tile's) app also makes the float key, so the key
/// transfer must be ordered strictly after the last raise completed — hence
/// `nativeRaiseAndWait`, and the same-app 0x0d dance from the last raised same-app float
/// (the actual key holder) to the tile. Never `setFrontProcess` here: that restacks the tile
/// above the floats.
@MainActor
func settleFloatLayerKeepingTileKey(tileWindowId: UInt32) async {
    guard let tile = Window.get(byId: tileWindowId) else { return }
    let tilePid = tile.app.pid
    var keyStealingFloatId: UInt32? = nil
    for workspace in Workspace.allUnsorted where workspace.isVisible {
        let floats = workspace.floatingWindowsContainer.mruChildren.compactMap { $0 as? Window }
        for window in floats.reversed() {
            if Task.isCancelled { return }
            await window.nativeRaiseAndWait()
            if window.app.pid == tilePid { keyStealingFloatId = window.windowId }
        }
    }
    if Task.isCancelled { return }
    // Give the float's app a beat to process the raise-induced key steal before re-keying.
    await PrivateFocus.asyncSleepNanoseconds(20_000_000)
    if Task.isCancelled { return }
    await floatClickKeyTransfer(tilePid, tileWindowId, keyStealingFloatId)
    (tile.app as? MacApp)?.lastNativeFocusedWindowId = tileWindowId
    if let mac = tile as? MacWindow {
        mac.macApp.setMainWithoutRaise(tileWindowId)
    }
    WindowBordersManager.shared.syncActiveFocus()
}

/// Initial keyboard focus for a tile click (may use setFrontProcess — call **before**
/// raising floats, never after).
@MainActor
private func assertTileKeyboardFocus(windowId: UInt32, previousKeyWindowId: UInt32?) {
    guard let window = Window.get(byId: windowId) else { return }
    let pid = window.app.pid
    let fallback = (window.app as? MacApp)?.lastNativeFocusedWindowId
    let forceFrom = previousKeyWindowId
        ?? workspaceFloatingWindowIds(containing: window).first
        ?? PrivateFocus.trackedKeyWindowId
    _ = PrivateFocus.focusWithoutRaise(
        pid: pid,
        windowId: windowId,
        fallbackPreviousKeyWindowId: fallback,
        forcePreviousKeyWindowId: forceFrom == windowId ? nil : forceFrom,
        sameAppGapMicroseconds: 0,
    )
    (window.app as? MacApp)?.lastNativeFocusedWindowId = windowId
    if let mac = window as? MacWindow {
        mac.macApp.setMainWithoutRaise(windowId)
    }
}

@MainActor
private func workspaceFloatingWindowIds(containing window: Window) -> [UInt32] {
    guard let ws = window.nodeWorkspace else { return [] }
    return ws.floatingWindows.map(\.windowId)
}

private enum FloatClickAction {
    case passThrough
    case swallow
    case beginPending(windowId: UInt32, pid: pid_t, clickState: Int64)
    case deliverPidMouseUp(pid: pid_t, at: CGPoint, clickState: Int64)
    case beginHidDrag(down: CGPoint, current: CGPoint, clickState: Int64)
    case hidDragMove(at: CGPoint, clickState: Int64)
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
        case .deliverPidMouseUp(let pid, let at, let clickState):
            postPidMouse(to: pid, type: .leftMouseUp, at: at, clickState: clickState)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    let tileId = floatClickStream?.windowId
                    floatClickStream = nil
                    // orderFront on mouseDown may have sunk C. Raise floats **last** (awaited),
                    // then transfer key (never setFrontProcess after raise — that put B above C).
                    if let tileId {
                        scheduleFloatLayerSettle(tileWindowId: tileId)
                    }
                }
            }
            return nil
        case .beginHidDrag(let down, let current, let clickState):
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
    if type == .leftMouseDown, floatClickStream != nil {
        endFloatClickStream(restoreFloatLayer: true)
    }

    if var stream = floatClickStream {
        stream.lastQuartz = quartzLocation
        stream.clickState = max(stream.clickState, clickState)

        let released = type == .leftMouseUp || (type == .mouseMoved && !leftButtonDown)
        let motion = type == .leftMouseDragged || type == .mouseMoved

        switch stream.phase {
            case .pending:
                if released {
                    floatClickStream = stream
                    return .deliverPidMouseUp(pid: stream.pid, at: quartzLocation, clickState: stream.clickState)
                }
                if motion, leftButtonDown || type == .leftMouseDragged {
                    if FloatClickWithoutRaisePolicy.isDrag(from: stream.downQuartz, to: quartzLocation) {
                        stream.phase = .hidDrag
                        floatClickStream = stream
                        return .beginHidDrag(
                            down: stream.downQuartz,
                            current: quartzLocation,
                            clickState: stream.clickState,
                        )
                    }
                    floatClickStream = stream
                    return .swallow
                }
                floatClickStream = stream
                return .swallow

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
    let top: Window
    if let targetId = SkyLight.findEventTargetWindow(at: quartzLocation) {
        if let managed = Window.get(byId: targetId) {
            top = managed
        } else if NSApp.window(withWindowNumber: Int(targetId)) != nil {
            // Our own alpha-passthrough overlays (tab bar / status bar) can win the WS hit test
            // in their transparent regions — resolve what's really under the click via the model
            guard let scanned = topmostManagedWindow(at: location) else { return .passThrough }
            top = scanned
        } else {
            // The true click target is a window we don't manage: a menu, panel, dialog, or
            // another app's float sitting above our tiles. The click is theirs — never intercept
            return .passThrough
        }
    } else {
        // SLSFindWindowAndOwner unavailable (symbol drift) — model-based scan fallback
        guard let scanned = topmostManagedWindow(at: location) else { return .passThrough }
        top = scanned
    }

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
    // A new gesture supersedes any in-flight settle — its own mouseUp settles again, and a
    // mid-press raise of C would race the click the same way the old reinforce Task did.
    cancelFloatLayerSettle()
    // Capture who had key *before* tree focus (usually float C). Borders track tree focus;
    // keyboard must be moved off this id explicitly.
    let previousKeyWindowId = focus.windowOrNil?.windowId
        ?? PrivateFocus.trackedKeyWindowId
        ?? (Window.get(byId: windowId).flatMap { ($0.app as? MacApp)?.lastNativeFocusedWindowId })

    floatClickStream = FloatClickStream(
        windowId: windowId,
        pid: pid,
        downQuartz: quartz,
        lastQuartz: quartz,
        clickState: clickState,
        phase: .pending,
        pidDownPosted: false,
        previousKeyWindowId: previousKeyWindowId,
    )
    guard let window = Window.get(byId: windowId) else { return }

    // 1) AeroSpace tree focus (borders / model) — always immediate.
    _ = window.focusWindow()
    WindowBordersManager.shared.syncActiveFocus()

    // 2) OS keyboard focus without raise (before any float raise).
    assertTileKeyboardFocus(windowId: windowId, previousKeyWindowId: previousKeyWindowId)

    // 3) Arm the app immediately (may orderFront the tile above C for the duration of the
    //    press — accepted; the settle on mouseUp restores the float layer). No mid-press
    //    reinforce here: a second settle racing the mouseUp one is what caused the thrash.
    postPidMouse(to: pid, type: .leftMouseDown, at: quartz, clickState: clickState)
    if var s = floatClickStream {
        s.pidDownPosted = true
        floatClickStream = s
    }

    if let token: RunSessionGuard = .isServerEnabled {
        Task { @MainActor in
            try? await runLightSession(.focusFollowsMouse, token) {}
            WindowBordersManager.shared.syncActiveFocus()
        }
    }
}

/// Click-path hit test: **float layer first**, then CG stack, then tiling layout.
@MainActor
func topmostManagedWindow(at location: CGPoint) -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace

    for child in workspace.floatingWindowsContainer.mruChildren {
        guard let child = child as? Window else { continue }
        if child.isHiddenInCorner { continue }
        if floatingWindowFrame(child)?.contains(location) == true {
            return child
        }
    }

    // First hit wins: the frontmost window containing the point decides. Walking past
    // non-tile hits used to reroute clicks that belonged to unmanaged windows (dialogs,
    // other apps' panels) or stale-rect floats sitting above the tile.
    let stack = onScreenWindowSnapshot().normalStack
    for item in stack {
        guard item.rect.contains(location) else { continue }
        guard let window = Window.get(byId: item.id) else { return nil } // unmanaged on top: click is theirs
        if window.isHiddenInCorner { continue }
        if window.isFloating { return window } // model rect in phase 1 was stale — still a float hit
        if window.nodeWorkspace == workspace { return window }
        if window.isSticky, window.nodeMonitor?.activeWorkspace == workspace { return window }
        return nil // managed but belongs elsewhere (other workspace) — don't claim the click
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
