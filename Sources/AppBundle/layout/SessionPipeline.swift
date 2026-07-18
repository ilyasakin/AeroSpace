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
/// - **Light**: command path. Fast. Does not discover new windows. May schedule heavy after.
/// - **Heavy**: discovery + normalize + layout. Does not clear frames-written (protects light→heavy lag).
/// - **Query-only light**: list/echo/test — skip layout and follow-up heavy.
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
        )
    }

    static func planLight(event: RefreshSessionEvent) -> Plan {
        let queryOrFfm = event.isQueryOnly || event.isFocusFollowsMouse
        return Plan(
            clearFramesWritten: true,
            optimisticLayout: false,
            discoverWindows: false,
            normalizeNativeState: false,
            layout: !queryOrFfm,
            scheduleFollowUpHeavy: !queryOrFfm,
            followUpOptimisticLayout: false,
        )
    }

    // MARK: - Heavy

    static func runHeavy(
        _ event: RefreshSessionEvent,
        assumeCancellable: Bool,
        plan: Plan,
    ) async {
        let state = signposter.beginInterval(
            "SessionPipeline.heavy",
            "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)",
        )
        defer { signposter.endInterval("SessionPipeline.heavy", state) }
        if !TrayMenuModel.shared.isEnabled { return }

        phaseBegin(clearFramesWritten: plan.clearFramesWritten)

        let res = await Result {
            try await $refreshSessionEvent.withValue(event) {
                try await phaseSyncFocusFromNative()
                if plan.optimisticLayout { try await phaseLayout() }

                await phaseModelHygiene()
                if plan.discoverWindows { try await phaseDiscoverWindows() }
                gcMonitors()

                // Tray can update early (focus/workspace names); borders wait until after layout
                phaseSideUiTrayAndSecureInput()

                if plan.normalizeNativeState { try await phaseNormalizeNativeState() }
                if plan.layout { try await phaseLayout() }
                // Immutable structural snapshot after layout (lock-screen / #1215 history)
                TreeHistory.recordLive()
                phaseSideUiBorders()
            }
        }
        switch res {
            case .success(()): break
            case .failure(let err as CancellationError):
                check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
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

        activeRefreshTask?.cancel() // Give priority to light session over pending heavy
        activeRefreshTask = nil

        phaseBegin(clearFramesWritten: plan.clearFramesWritten)

        return try await $refreshSessionEvent.withValue(event) {
            try await phaseSyncFocusFromNative()
            let focusBefore = focus.windowOrNil

            await phaseModelHygiene()
            let result = try await body()
            await phaseModelHygiene()

            let focusAfter = focus.windowOrNil

            phaseSideUiTrayAndSecureInput()
            if plan.layout {
                try await phaseLayout()
                TreeHistory.recordLive()
            }

            phaseSideUiBorders()

            if focusBefore != focusAfter {
                focusAfter?.nativeFocus() // syncFocusToMacOs
            }
            if plan.scheduleFollowUpHeavy {
                scheduleCancellableCompleteRefreshSession(
                    event,
                    optimisticallyPreLayoutWorkspaces: plan.followUpOptimisticLayout,
                )
            }
            return result
        }
    }

    // MARK: - Phases

    /// Phase 1 — session-local caches. See Plan.clearFramesWritten for the SkyLight write-lag policy.
    private static func phaseBegin(clearFramesWritten: Bool) {
        invalidateWindowLevelCache()
        invalidateMonitorsCache()
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

    /// Phase 7 — tiling layout + hide-in-corner for invisible workspaces
    private static func phaseLayout() async throws {
        try await layoutWorkspaces()
    }

    /// Phase 8a — tray / secure input (safe before or after layout)
    private static func phaseSideUiTrayAndSecureInput() {
        updateTrayText()
        SecureInputPanel.shared.refresh()
    }

    /// Phase 8b — borders (must run after layout when layout ran this session)
    private static func phaseSideUiBorders() {
        WindowBordersManager.shared.refresh()
    }
}

// MARK: - Task handle (shared with schedule)

@MainActor
var activeRefreshTask: Task<(), any Error>? = nil
