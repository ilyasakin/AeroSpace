import AppKit
import Common

/// Explicit session pipeline for the AeroSpace server.
///
/// All mutating work that touches windows, the tree, or side UI goes through phases with a fixed
/// order. That order is load-bearing (e.g. borders after layout; frames-written marks survive
/// light→heavy). Prefer extending this file over sprinkling one-off calls in observers/commands.
///
/// ## Phases (in order)
/// 1. **Begin** — invalidate per-session caches; light sessions clear SkyLight write marks
/// 2. **Focus-from-native** — read macOS focus into the tree
/// 3. **Model hygiene** — GC empty workspaces, normalize containers, focus callbacks
/// 4. **Command body** (light only) — user/hotkey/CLI command
/// 5. **Discover** (heavy only) — AX alive-window scan, register/gc MacWindows
/// 6. **Normalize layout reason** (heavy only) — fullscreen/minimized/hidden reparent
/// 7. **Layout** — apply tiling geometry (AX writes; marks frames-written)
/// 8. **Side UI** — tray, secure-input HUD, window borders (must run after layout when layout ran)
/// 9. **End** — sync focus to macOS if needed; schedule follow-up heavy discovery
///
/// ## Session kinds
/// - **Light**: command path. Fast. Does not discover new windows. May schedule heavy after
///   only when `event.needsDiscoveryFollowUp` (startup/config/mouse-up settle) — not every hotkey.
/// - **Heavy**: discovery + normalize + layout. Does not clear frames-written (protects light→heavy lag).
/// - **Query-only light**: list/echo/test — skip layout and follow-up heavy.
/// - **FFM light**: no layout, no borders/status, no heavy cancel; tray only if tray fingerprint changes.
/// - **Mouse-manipulate light**: layout only (live tiling); no side-UI rebuild, no follow-up heavy
///   (borders track via WindowServer; mouse-up runs one complete heavy). High-frequency: no focus
///   AX, no hygiene, no heavy-cancel, no session-cache thrash — sibling frames stay smooth.
@MainActor
enum SessionPipeline {
    /// The window macOS just told us is focused (the window of a kAXFocusedWindowChanged, or the
    /// one we asked for when its app's activation arrives). The session then skips asking the app
    /// again: two AX round trips, 20-30 ms each on a busy machine, for an answer already in hand.
    /// Task-local, so it reaches exactly the session started under it.
    @TaskLocal static var nativeFocusHint: UInt32? = nil

    /// Policy knobs for one session. Built from the event; not free-form at call sites.
    struct Plan: Equatable {
        /// Optional optimistic layout before discover (app activation path)
        var optimisticLayout: Bool
        /// Heavy: MacApp.refreshAll + register/gc windows
        var discoverWindows: Bool
        /// Heavy: native fullscreen/minimized/hidden reparent
        var normalizeNativeState: Bool
        /// Apply tiling/floating geometry
        var layout: Bool
        /// After a mutating light session, schedule cancellable heavy for discovery
        var scheduleFollowUpHeavy: Bool
        /// optimisticallyPreLayoutWorkspaces flag for the follow-up heavy task
        var followUpOptimisticLayout: Bool
        /// Redraw borders / group tabs / status bar (expensive; skip FFM + mouse-drag)
        var sideUiBorders: Bool = true
        /// Update tray text / secure input
        var sideUiTray: Bool = true
        /// Tray leaf-walk only when needed (FFM uses cheap fingerprint gate)
        var trayFullLeafWalk: Bool = true
        /// Skip native-focus AX + model hygiene (FFM + mouse-drag hot path)
        var skipFocusAndHygiene: Bool = false
        /// Do not cancel in-flight heavy discovery (FFM + mouse-drag)
        var skipHeavyCancel: Bool = false
        /// Invalidate window-level / monitors caches at session start (skip on high-frequency)
        var invalidateSessionCaches: Bool = true
        /// Layout only visible workspaces (skip hide-in-corner). Mouse-drag only.
        var layoutVisibleOnly: Bool = false
    }

    // MARK: - Plan

    static func planHeavy(
        layout: Bool,
        optimisticLayout: Bool,
    ) -> Plan {
        Plan(
            optimisticLayout: optimisticLayout && layout,
            discoverWindows: true,
            normalizeNativeState: true,
            layout: layout,
            scheduleFollowUpHeavy: false,
            followUpOptimisticLayout: false,
            sideUiBorders: true,
            sideUiTray: true,
            trayFullLeafWalk: true,
        )
    }

    /// Build light-session policy.
    /// - `mouseManipulate`: continuous drag move/resize (button down + known manipulated window).
    static func planLight(event: RefreshSessionEvent, mouseManipulate: Bool = false) -> Plan {
        let isFfm = event.isFocusFollowsMouse
        let queryOrFfm = event.isQueryOnly || isFfm
        let drag = mouseManipulate && event.isAx
        let highFreq = isFfm || drag
        return Plan(
            // High-frequency paths must not churn framesWritten / session caches every event.
            optimisticLayout: false,
            discoverWindows: false,
            normalizeNativeState: false,
            layout: !queryOrFfm, // drag still layouts for live tiling siblings
            // Pure focus/geometry lights: no rediscovery. Create/destroy use direct heavy.
            // Drag: no follow-up (mouse-up schedules one complete heavy).
            scheduleFollowUpHeavy: !queryOrFfm && !drag && event.needsDiscoveryFollowUp,
            followUpOptimisticLayout: false,
            // Hover + drag must not rebuild borders/status/group tabs every tick.
            // Live drag geometry is WindowServer → WindowBordersManager.handleWindowMoved.
            // Queries (list-*, test, echo) change nothing a bar or border shows — status-bar
            // scripts poll them per workspace switch, each one used to rebuild every side UI.
            sideUiBorders: !isFfm && !drag && !event.isQueryOnly,
            // Drag: tray idle until mouse-up. FFM: tray only if focus/workspace fingerprint changes.
            sideUiTray: !drag && !event.isQueryOnly,
            trayFullLeafWalk: !isFfm,
            skipFocusAndHygiene: highFreq,
            // A query must not pre-empt pending discovery (it would only be re-queued after)
            skipHeavyCancel: highFreq || event.isQueryOnly,
            invalidateSessionCaches: !highFreq,
            // Drag: only paint visible tiles — hide-in-corner of other spaces is idle work.
            layoutVisibleOnly: drag,
        )
    }

    // MARK: - Heavy

    /// - Returns: `true` if the heavy completed fully; `false` if cancelled (or disabled).
    ///   Callers that track discovery obligations must not clear them on `false`.
    @discardableResult
    static func runHeavy(
        _ event: RefreshSessionEvent,
        assumeCancellable: Bool,
        plan: Plan,
    ) async -> Bool {
        let state = signposter.beginInterval(
            "SessionPipeline.heavy",
            "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)",
        )
        defer { signposter.endInterval("SessionPipeline.heavy", state) }
        if !ServerState.isEnabled { return true }
        SessionStats.noteHeavy(event)

        phaseBegin()
        var clock = SessionClock("heavy \(event.statsCause)")
        defer { clock.log() }

        let res = await Result {
            try await $refreshSessionEvent.withValue(event) {
                // macOS's report is judged against what discovery and native-state handling learn:
                // after cmd-W / cmd-M / cmd-H macOS has already handed focus to another window of
                // the app, maybe one parked on a hidden workspace. Read first, the model followed
                // it there before the close/minimize/hide that makes it a hand-off was even known.
                // The optimistic pre-layout (app activation) needs the user's focus up front.
                let reportFocusEarly = plan.optimisticLayout || !plan.discoverWindows && !plan.normalizeNativeState
                if reportFocusEarly { try await phaseSyncFocusFromNative(); clock.mark("focus") }
                if plan.optimisticLayout { try await phaseLayout(visibleOnly: false); clock.mark("prelayout") }

                await phaseModelHygiene()
                clock.mark("hygiene")
                if plan.discoverWindows { try await phaseDiscoverWindows(); clock.mark("discover") }
                gcMonitors()

                // Tray can update early (focus/workspace names); borders wait until after layout
                if plan.sideUiTray {
                    phaseSideUiTrayAndSecureInput(fullLeafWalk: plan.trayFullLeafWalk)
                }

                if plan.normalizeNativeState {
                    try await phaseNormalizeNativeState()
                    clock.mark("native-state")
                    // Discovery GC (app-initiated close) and native-state reparenting (minimize,
                    // fullscreen, hide) both ran AFTER hygiene; without this, layout would place
                    // empty containers and single-child wrappers, and the layout would jump again
                    // on the next session. i3 closes empty containers immediately.
                    normalizeAllContainers()
                }
                // A startup restore that found no windows (apps slower than AeroSpace at login)
                // retries here now that discovery has run — before layout cements placements.
                if !reportFocusEarly { try await phaseSyncFocusFromNative(); clock.mark("focus") }
                SessionLayoutStore.retryRestoreIfPending()
                if plan.layout { try await phaseLayout(visibleOnly: false); clock.mark("layout") }
                // Discovery can change the model's focus (a closed window, a fullscreen rule)
                FocusReconciler.reconcile()
                SessionLayoutStore.scheduleSave()
                if plan.sideUiBorders {
                    try await refreshStaleTabTitles()
                    phaseSideUiBorders()
                    clock.mark("side-ui")
                }
                if plan.layout { HoverFocus.reanchorToPointer() }
            }
        }
        switch res {
            case .success(()): return true
            case .failure(let err as CancellationError):
                check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
                return false
            case .failure(let err): die("Illegal error: \(err)")
        }
    }

    // MARK: - Light

    static func runLight<T>(
        _ event: RefreshSessionEvent,
        plan: Plan,
        body: @MainActor () async throws -> T,
    ) async throws -> T {
        let state = signposter.beginInterval(
            "SessionPipeline.light",
            "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)",
        )
        defer { signposter.endInterval("SessionPipeline.light", state) }
        SessionStats.lightSessions += 1

        // Focus-follows-mouse and mouse-drag must not cancel heavy (starves discovery; thrash).
        // Other lights may cancel a pending heavy for priority — but then we re-queue discovery
        // after the light if nothing else schedules follow-up (see sessionShouldRescheduleCancelledDiscovery).
        // noteHeavyCancelledByLightSession also bumps generation so a mid-flight heavy that
        // swallows CancellationError cannot clear discoveryHeavyPending on return.
        if !plan.skipHeavyCancel {
            noteHeavyCancelledByLightSession()
        }

        phaseBegin(invalidateSessionCaches: plan.invalidateSessionCaches)
        var clock = SessionClock("light \(event.statsCause)")
        defer { clock.log() }

        return try await $refreshSessionEvent.withValue(event) {
            // Hover/drag: skip native-focus AX + hygiene thrash; body owns the mutation.
            if !plan.skipFocusAndHygiene {
                // A deadline for every light session, not only commands: an activation or
                // focus-changed session reading a beachballing app's focus held the kernel for
                // seconds, and the hotkey pressed to get away queued behind it. On timeout the
                // read is retried by a heavy (which a light session can pre-empt).
                let deadline: Double = event.isCommand ? lightSessionFocusReadDeadline : 0.5
                if let hint = Self.nativeFocusHint, let hinted = Window.get(byId: hint) {
                    FocusReconciler.macosReported(hinted)
                } else if try await !phaseSyncFocusFromNative(deadline: deadline) {
                    // Timed out: reconcile focus once the app answers
                    scheduleCancellableCompleteRefreshSession(event)
                }
                clock.mark("focus")
            }
            let focusBefore = focus.windowOrNil

            if !plan.skipFocusAndHygiene {
                await phaseModelHygiene()
            }
            let result = try await body()
            clock.mark("command")
            if !plan.skipFocusAndHygiene {
                await phaseModelHygiene()
            }

            let focusAfter = focus.windowOrNil

            if plan.sideUiTray {
                phaseSideUiTrayAndSecureInput(fullLeafWalk: plan.trayFullLeafWalk)
            }
            if plan.layout {
                try await phaseLayout(visibleOnly: plan.layoutVisibleOnly)
                clock.mark("layout")
                // Drag skips sideUiBorders refresh; each moved window's own WindowServer event
                // repaints its border (borders never paint layout geometry)
                // Not on the high-frequency mouse-drag path (mouse-up's heavy saves)
                if plan.sideUiBorders || !event.isAx {
                    SessionLayoutStore.scheduleSave()
                }
            }

            // Body-owned paths (FFM / mouse-drag) send focus with their own raise policy.
            // Sent BEFORE side UI: the raise is what the user waits for; borders/bar redraw after.
            if !plan.skipFocusAndHygiene {
                FocusReconciler.reconcile()
                clock.mark("focus-send")
            }

            if plan.sideUiBorders {
                try await refreshStaleTabTitles()
                phaseSideUiBorders()
                clock.mark("side-ui")
            }
            // Whatever is under a resting pointer after a keyboard/command focus change or a
            // layout change is "already entered" — hovering must not steal focus back
            if !event.isFocusFollowsMouse, plan.layout || focusBefore != focusAfter {
                HoverFocus.reanchorToPointer()
            }
            if plan.scheduleFollowUpHeavy {
                scheduleCancellableCompleteRefreshSession(
                    event,
                    optimisticallyPreLayoutWorkspaces: plan.followUpOptimisticLayout,
                )
            } else if sessionShouldRescheduleCancelledDiscovery(
                discoveryHeavyPending: discoveryHeavyPending,
                hasActiveHeavyTask: activeRefreshTask != nil,
                planSchedulesFollowUp: plan.scheduleFollowUpHeavy,
            ) {
                // Pure geometry/focus light cancelled a create/destroy/activate/mouse-up heavy —
                // re-queue one complete discovery so windows are not left unregistered.
                scheduleCancellableCompleteRefreshSession(event)
            }
            return result
        }
    }

    // MARK: - Phases

    /// Phase 1 — session-local caches (WindowServer lag after our own writes is the frame
    /// records' business, not the session's)
    private static func phaseBegin(invalidateSessionCaches: Bool = true) {
        if invalidateSessionCaches {
            invalidateWindowLevelCache()
            invalidateMonitorsCache()
        }
    }

    /// Phase 2 — macOS focused window → tree focus. With a `deadline` (light sessions: the hotkey
    /// path), an app too busy to answer within it leaves the tree's focus as it is instead of
    /// holding the command hostage for up to the AX messaging timeout.
    /// Returns false when the read timed out (focus left as it was)
    @discardableResult
    private static func phaseSyncFocusFromNative(deadline: Double? = nil) async throws -> Bool {
        let read: NativeFocusRead
        if let deadline {
            read = try await withDeadline(seconds: deadline, fallback: .timedOut) {
                .window(try await getNativeFocusedWindow(.cancellable)?.windowId)
            }
        } else {
            read = .window(try await getNativeFocusedWindow(.cancellable)?.windowId)
        }
        guard case .window(let id) = read else { return false }
        let nativeFocused = id.flatMap { Window.get(byId: $0) }
        if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
        FocusReconciler.macosReported(nativeFocused)
        return true
    }

    /// Phase 3 — tree hygiene without AX discovery
    private static func phaseModelHygiene() async {
        await refreshModel_nonCancellable()
    }

    /// Phase 5 — discover alive windows via AX (expensive; heavy only)
    private static func phaseDiscoverWindows() async throws {
        try await discoverAliveWindows()
    }

    /// Phase 6 — native fullscreen / minimized / hidden-app reparent
    private static func phaseNormalizeNativeState() async throws {
        try await normalizeLayoutReason()
    }

    /// Phase 7 — tiling layout (+ hide-in-corner for invisible workspaces unless `visibleOnly`)
    private static func phaseLayout(visibleOnly: Bool) async throws {
        try await layoutWorkspaces(includeInvisible: !visibleOnly)
    }

    /// Phase 8a — tray / secure input (safe before or after layout)
    private static func phaseSideUiTrayAndSecureInput(fullLeafWalk: Bool = true) {
        updateTrayText(fullLeafWalk: fullLeafWalk)
        SecureInputPanel.shared.refresh()
    }

    /// Phase 8b — borders (must run after layout when layout ran this session)
    private static func phaseSideUiBorders() {
        var clock = SessionClock("side-ui")
        defer { clock.log() }
        WindowBordersManager.shared.refresh()
        clock.mark("borders")
        WindowDimming.shared.refresh()
        GroupTabBarManager.shared.refresh()
        clock.mark("tab-bar")
        StatusBarManager.shared.refresh()
        clock.mark("status-bar")
    }
}

/// How long a light session waits for the frontmost app to report its focused window
let lightSessionFocusReadDeadline: Double = 0.1

private enum NativeFocusRead: Sendable {
    case timedOut
    case window(UInt32?)
}

// MARK: - Task handle (shared with schedule)

@MainActor
var activeRefreshTask: Task<(), any Error>? = nil

/// Per-session phase timing for frame-trace.log: `session <kind> <cause> 12.3ms focus=0.4 layout=8.1 …`
/// Only sessions that took at least `threshold` are logged, so idle traffic stays out of the log.
struct SessionClock {
    static let thresholdMs: Double = 4
    private let label: String
    private let start = ProcessInfo.processInfo.systemUptime
    private var last: TimeInterval
    private var phases: [(String, Double)] = []

    init(_ label: String) {
        self.label = label
        last = start
    }

    mutating func mark(_ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        phases.append((phase, (now - last) * 1000))
        last = now
    }

    func log() {
        let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard total >= Self.thresholdMs else { return }
        let parts = phases.filter { $0.1 >= 0.5 }.map { "\($0.0)=\(String(format: "%.1f", $0.1))" }
        FrameTrace.log("session \(label) \(String(format: "%.1f", total))ms " + parts.joined(separator: " "))
    }
}
