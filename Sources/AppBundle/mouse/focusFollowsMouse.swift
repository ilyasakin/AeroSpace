import AppKit
import ApplicationServices

/// Focus follows mouse (i3 `focus_follows_mouse`). The decision is `HoverFocusPolicy` (pure);
/// this is the plumbing: event source, focus application, and re-anchoring.
///
/// Event source: a LISTEN-ONLY event tap at the annotated session tap. WindowServer has already
/// hit-tested the event there, so the window under the pointer comes for free in the event fields —
/// no AX query, no CGWindowList scan, no hit test of our own per mouse move (the previous monitor
/// did an AX element-at-position round trip into the target app before every focus change and
/// re-scanned the window list on every move when floats existed). If the tap can't be created,
/// an NSEvent global monitor + `NSWindow.windowNumber(at:)` (public WindowServer hit test) is used.
@MainActor
enum HoverFocus {
    private static var pendingApply: Task<(), any Error>? = nil
    static var state = HoverState()
    /// Pointer location source (tests inject one; the real cursor must never leak into them)
    static var pointerLocation: () -> CGPoint = { mouseLocation }

    /// `eventSourceUserData` tag on the mouse events AeroSpace itself posts (`move-mouse`)
    nonisolated static let syntheticEventTag: Int64 = 0x4145_524F // "AERO"

    static var isRunning: Bool { PointerEvents.isObserving }

    static func sync(_ config: Config) {
        if config.focusFollowsMouse.enabled == isRunning { return }
        if config.focusFollowsMouse.enabled { start() } else { stop() }
    }

    private static func start() {
        PointerEvents.startObserving { handle($0) }
        reanchorToPointer()
    }

    private static func stop() {
        PointerEvents.stopObserving()
        pendingApply?.cancel()
        pendingApply = nil
        state = HoverState()
    }

    static func handle(_ sample: HoverSample) {
        let decision = HoverFocusPolicy.decide(sample, &state, context(now: ProcessInfo.processInfo.systemUptime))
        guard case .focus(let windowId) = decision else { return }
        pendingApply?.cancel()
        pendingApply = Task.startUnstructured { @MainActor in
            try await apply(windowId)
        }
    }

    static func context(now: TimeInterval) -> HoverContext {
        HoverContext(
            enabled: config.focusFollowsMouse.enabled && ServerState.isEnabled,
            isDragging: currentlyManipulatedWithMouseWindowId != nil,
            focusedWindowId: focus.windowOrNil?.windowId,
            now: now,
            isFocusable: { isHoverFocusable($0) },
            modelHit: { windowUnderMouseCheap($0)?.windowId },
        )
    }

    /// Tree focus in a (cheap, layout-less) FFM light session, then OS focus: floats raise like
    /// any window; a tile is focused WITHOUT raising (unless `raise = true`) so a floating window
    /// over it stays visible, as in i3.
    ///
    /// One kernel job for both halves: the OS focus used to be applied AFTER the session returned,
    /// so another session could change focus in between and this hover would then natively focus a
    /// window the tree no longer considered focused.
    static func apply(_ windowId: UInt32) async throws {
        try await Kernel.exclusive("hover focus") { try await applyInKernel(windowId) }
    }

    private static func applyInKernel(_ windowId: UInt32) async throws {
        guard let token: RunSessionGuard = .isServerEnabled, let window = Window.get(byId: windowId) else { return }
        try checkCancellation()
        let previous = focus.windowOrNil?.windowId
        try await runLightSession(.focusFollowsMouse, token) {
            _ = window.focusWindow()
        }
        try checkCancellation()
        if config.focusFollowsMouse.raise || window.isFloating {
            window.nativeFocus()
        } else {
            // Only a same-app previous window takes part in the 0x0D unfocus/focus switch
            let samePid = previous.flatMap { Window.get(byId: $0) }?.app.pid == window.app.pid
            let ok = await window.nativeFocusWithoutRaise(previousKeyWindowId: samePid ? previous : nil)
            // Superseded by a newer hover mid-switch: raising THIS window now would steal focus
            // from where the pointer went (and cover a float)
            try checkCancellation()
            if !ok { window.nativeFocus() }
        }
        FocusReconciler.noteRequested(window.windowId)
        // FFM light sessions skip sideUiBorders — still move the active border style
        WindowBordersManager.shared.syncActiveFocus()
    }

    /// See `HoverFocusPolicy.reanchor`. Called after every non-hover session that changed focus
    /// or layout.
    static func reanchorToPointer() {
        guard config.focusFollowsMouse.enabled else { return }
        HoverFocusPolicy.reanchor(&state, windowUnderPointer: windowUnderMouseCheap(pointerLocation())?.windowId)
    }

    static func resetForTests() {
        pendingApply?.cancel()
        pendingApply = nil
        state = HoverState()
        pointerLocation = { mouseLocation }
    }

    /// Wait for the focus application a hover started (tests)
    static func settleForTests() async { _ = await pendingApply?.result }

    /// Managed, focusable, and on a workspace that is actually showing
    static func isHoverFocusable(_ id: UInt32) -> Bool {
        guard let window = Window.get(byId: id), !window.isHiddenInCorner else { return false }
        switch window.parent?.cases {
            case .tilingContainer, .floatingWindowsContainer: break
            default: return false
        }
        guard let ws = window.nodeWorkspace else { return false }
        return ws.isVisible || (window.isSticky && window.nodeMonitor?.activeWorkspace.isVisible == true)
    }
}


@MainActor func syncFocusFollowsMouse(_ config: Config) {
    HoverFocus.sync(config)
}

/// Geometry hit test. Floating windows always beat tiles they cover (live frame), then
/// front-to-back stack, then tiling layout rects.
@MainActor
func windowUnderMouseCheap(_ location: CGPoint) -> Window? {
    let workspace = location.monitorApproximation.activeWorkspace

    // 1) Floats first using live/believed frames — independent of stale CGWindowList cache.
    //    Treat any float containing the point as above the tiling layer for hit purposes.
    for child in workspace.floatingWindowsContainer.mruChildren {
        guard let child = child as? Window else { continue }
        if floatingWindowFrame(child)?.contains(location) == true {
            return child
        }
    }

    // 2) Front-to-back stack among remaining candidates (fresh each call when floats exist).
    if !workspace.floatingWindows.isEmpty {
        invalidateOnScreenWindowSnapshot()
    }
    let stack = onScreenWindowSnapshot().normalStack
    for item in stack {
        guard item.rect.contains(location) else { continue }
        guard let window = Window.get(byId: item.id) else { continue }
        guard windowIsEligibleForFfm(window, on: workspace) else { continue }
        // Floats already handled above; skip so we don't re-hit with stale stack order.
        if window.isFloating { continue }
        return window
    }

    // 3) Tiling layout rects (desired / virtual).
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

@MainActor
private func windowIsEligibleForFfm(_ window: Window, on workspace: Workspace) -> Bool {
    if window.isHiddenInCorner { return false }
    if window.nodeWorkspace == workspace { return true }
    // Sticky floats/tiles follow the monitor's active workspace.
    if window.isSticky, window.nodeMonitor?.activeWorkspace == workspace { return true }
    return false
}

/// Live or believed frame for a floating window (layout clears belief on some paths).
@MainActor
func floatingWindowFrame(_ window: Window) -> Rect? {
    if let applied = window.knownFrame ?? window.lastAppliedLayoutVirtualRect {
        return applied
    }
    return WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
}
