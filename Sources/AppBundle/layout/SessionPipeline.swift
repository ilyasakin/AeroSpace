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
    /// Policy knobs for one session. Built from the event; not free-form at call sites.
    struct Plan: Equatable {
        /// Light only: drop SkyLight "written this session" marks so the next command starts clean
        var clearFramesWritten: Bool
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
            clearFramesWritten: false, // keep marks across light→heavy lag
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
            clearFramesWritten: !highFreq,
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
            sideUiBorders: !isFfm && !drag,
            // Drag: tray idle until mouse-up. FFM: tray only if focus/workspace fingerprint changes.
            sideUiTray: !drag,
            trayFullLeafWalk: !isFfm,
            skipFocusAndHygiene: highFreq,
            skipHeavyCancel: highFreq,
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
        if !TrayMenuModel.shared.isEnabled { return true }

        phaseBegin(clearFramesWritten: plan.clearFramesWritten)

        let res = await Result {
            try await $refreshSessionEvent.withValue(event) {
                try await phaseSyncFocusFromNative()
                if plan.optimisticLayout { try await phaseLayout(visibleOnly: false) }

                await phaseModelHygiene()
                if plan.discoverWindows { try await phaseDiscoverWindows() }
                gcMonitors()

                // Tray can update early (focus/workspace names); borders wait until after layout
                if plan.sideUiTray {
                    phaseSideUiTrayAndSecureInput(fullLeafWalk: plan.trayFullLeafWalk)
                }

                if plan.normalizeNativeState { try await phaseNormalizeNativeState() }
                if plan.layout { try await phaseLayout(visibleOnly: false) }
                // Immutable structural snapshot after layout (lock-screen / #1215 history)
                TreeHistory.recordLive()
                if plan.sideUiBorders {
                    phaseSideUiBorders()
                }
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

        // Focus-follows-mouse and mouse-drag must not cancel heavy (starves discovery; thrash).
        // Other lights may cancel a pending heavy for priority — but then we re-queue discovery
        // after the light if nothing else schedules follow-up (see sessionShouldRescheduleCancelledDiscovery).
        // noteHeavyCancelledByLightSession also bumps generation so a mid-flight heavy that
        // swallows CancellationError cannot clear discoveryHeavyPending on return.
        if !plan.skipHeavyCancel {
            noteHeavyCancelledByLightSession()
        }

        phaseBegin(
            clearFramesWritten: plan.clearFramesWritten,
            invalidateSessionCaches: plan.invalidateSessionCaches,
        )

        return try await $refreshSessionEvent.withValue(event) {
            // Hover/drag: skip native-focus AX + hygiene thrash; body owns the mutation.
            if !plan.skipFocusAndHygiene {
                try await phaseSyncFocusFromNative()
            }
            let focusBefore = focus.windowOrNil

            if !plan.skipFocusAndHygiene {
                await phaseModelHygiene()
            }
            let result = try await body()
            if !plan.skipFocusAndHygiene {
                await phaseModelHygiene()
            }

            let focusAfter = focus.windowOrNil

            if plan.sideUiTray {
                phaseSideUiTrayAndSecureInput(fullLeafWalk: plan.trayFullLeafWalk)
            }
            if plan.layout {
                try await phaseLayout(visibleOnly: plan.layoutVisibleOnly)
                // Drag skips sideUiBorders refresh; push layout rects into the overlay so sibling
                // borders do not lag a frame on WindowServer (wrong edges, then snap-correct).
                if plan.layoutVisibleOnly {
                    WindowBordersManager.shared.syncAfterMouseLayout()
                }
                // Skip history capture on high-frequency mouse-drag (mouse-up heavy will capture).
                if plan.sideUiBorders || !event.isAx {
                    TreeHistory.recordLive()
                }
            }

            if plan.sideUiBorders {
                phaseSideUiBorders()
            }

            if focusBefore != focusAfter {
                focusAfter?.nativeFocus() // syncFocusToMacOs
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

    /// Phase 1 — session-local caches. See Plan.clearFramesWritten for the SkyLight write-lag policy.
    private static func phaseBegin(clearFramesWritten: Bool, invalidateSessionCaches: Bool = true) {
        if invalidateSessionCaches {
            invalidateWindowLevelCache()
            invalidateMonitorsCache()
        }
        if clearFramesWritten {
            clearFramesWrittenThisSession()
        }
    }

    /// Phase 2 — macOS focused window → tree focus
    private static func phaseSyncFocusFromNative() async throws {
        let nativeFocused = try await getNativeFocusedWindow(.cancellable)
        if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
        updateFocusCache(nativeFocused)
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
        WindowBordersManager.shared.refresh()
        GroupTabBarManager.shared.refresh()
        StatusBarManager.shared.refresh()
    }
}

// MARK: - Task handle (shared with schedule)

@MainActor
var activeRefreshTask: Task<(), any Error>? = nil
