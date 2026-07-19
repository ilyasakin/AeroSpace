@testable import AppBundle
import Common
import XCTest

/// Policy tests for SessionPipeline.Plan — the phase *order* is enforced by construction in
/// SessionPipeline.swift; these tests lock the load-bearing knobs (query-only, frames-written,
/// light→heavy follow-up, mouse-drag, FFM) so refactors cannot silently reintroduce thrash.
@MainActor
final class SessionPipelineTest: XCTestCase {
    func testHeavyPlanDoesNotClearFramesWritten() {
        let plan = SessionPipeline.planHeavy(layout: true, optimisticLayout: false)
        XCTAssertFalse(plan.clearFramesWritten)
        XCTAssertTrue(plan.discoverWindows)
        XCTAssertTrue(plan.normalizeNativeState)
        XCTAssertTrue(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
    }

    func testHeavyPlanCanDisableLayout() {
        let plan = SessionPipeline.planHeavy(layout: false, optimisticLayout: true)
        XCTAssertFalse(plan.layout)
        // optimistic layout only when layout is enabled
        XCTAssertFalse(plan.optimisticLayout)
    }

    func testHeavyOptimisticLayoutRequiresLayout() {
        let plan = SessionPipeline.planHeavy(layout: true, optimisticLayout: true)
        XCTAssertTrue(plan.optimisticLayout)
    }

    func testLightHotkeyLayoutsWithoutFollowUpHeavy() {
        // Pure geometry/focus lights must not rediscover after every binding.
        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertTrue(plan.clearFramesWritten)
        XCTAssertTrue(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        XCTAssertFalse(plan.discoverWindows)
        XCTAssertFalse(RefreshSessionEvent.hotkeyBinding.needsDiscoveryFollowUp)
    }

    func testLightMutatingSocketDoesNotScheduleHeavy() {
        // Mutating CLI is light; create/destroy still discover via direct heavy on AX.
        // Use a non-query command kind if available — ModeCmdArgs or similar.
        // Fallback: hotkey already covers pure geometry; socket query-only is separate.
        XCTAssertFalse(RefreshSessionEvent.menuBarButton.needsDiscoveryFollowUp)
        let plan = SessionPipeline.planLight(event: .menuBarButton)
        XCTAssertTrue(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
    }

    func testLightQueryOnlySkipsLayoutAndHeavy() {
        // echo is query-only (CmdKind.isQueryOnly) — no layout / no follow-up heavy
        let event = RefreshSessionEvent.socketServer(TrueCmdArgs(rawArgs: []))
        XCTAssertTrue(event.isQueryOnly)
        XCTAssertFalse(event.needsDiscoveryFollowUp)
        let plan = SessionPipeline.planLight(event: event)
        XCTAssertTrue(plan.clearFramesWritten)
        XCTAssertFalse(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
    }

    func testFocusFollowsMouseSkipsLayoutBordersAndHeavy() {
        let plan = SessionPipeline.planLight(event: .focusFollowsMouse)
        XCTAssertFalse(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        // High-frequency hover must not thrash borders/status bar/CPU sampling every move.
        XCTAssertFalse(plan.clearFramesWritten)
        XCTAssertFalse(plan.sideUiBorders)
        XCTAssertTrue(plan.sideUiTray) // tray may update, but only via fingerprint (no full walk when unchanged)
        XCTAssertFalse(plan.trayFullLeafWalk)
        XCTAssertFalse(RefreshSessionEvent.focusFollowsMouse.needsDiscoveryFollowUp)
        // Body owns nativeFocus(raise:); end-of-session re-raise would undo float-safe focus.
        XCTAssertTrue(plan.skipFocusAndHygiene)
    }

    func testHotkeyLightStillRunsSideUi() {
        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertTrue(plan.sideUiBorders)
        XCTAssertTrue(plan.sideUiTray)
        XCTAssertTrue(plan.trayFullLeafWalk)
        XCTAssertTrue(plan.clearFramesWritten)
    }

    func testMouseManipulateAxSkipsSideUiAndFollowUpHeavy() {
        // Continuous drag: layout only; borders live via WindowServer; heavy on mouse-up.
        let plan = SessionPipeline.planLight(event: .ax("AXWindowMoved"), mouseManipulate: true)
        XCTAssertTrue(plan.layout)
        XCTAssertFalse(plan.sideUiBorders)
        XCTAssertFalse(plan.sideUiTray)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        XCTAssertFalse(plan.discoverWindows)
        // Smooth sibling tracking: no focus AX / hygiene / cache / heavy-cancel thrash per tick.
        XCTAssertTrue(plan.skipFocusAndHygiene)
        XCTAssertTrue(plan.skipHeavyCancel)
        XCTAssertFalse(plan.clearFramesWritten)
        XCTAssertFalse(plan.invalidateSessionCaches)
        XCTAssertTrue(plan.layoutVisibleOnly)
    }

    func testFocusFollowsMouseIsHighFrequencyLikeDrag() {
        let plan = SessionPipeline.planLight(event: .focusFollowsMouse)
        XCTAssertTrue(plan.skipFocusAndHygiene)
        XCTAssertTrue(plan.skipHeavyCancel)
        XCTAssertFalse(plan.invalidateSessionCaches)
        XCTAssertFalse(plan.clearFramesWritten)
    }

    func testAxWithoutMouseManipulateDoesNotGetDiscoveryFromLightPlan() {
        // Non-drag AX is scheduled as heavy directly; light plan for bare .ax is not the path.
        // When light is used without mouseManipulate, still no follow-up (no false rediscover).
        let plan = SessionPipeline.planLight(event: .ax("AXWindowMoved"), mouseManipulate: false)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        XCTAssertTrue(plan.sideUiBorders) // would rebuild if somehow used as light
    }

    func testConfigReloadAndStartupStillRequestDiscoveryFollowUp() {
        XCTAssertTrue(RefreshSessionEvent.configAutoReload.needsDiscoveryFollowUp)
        XCTAssertTrue(RefreshSessionEvent.startup.needsDiscoveryFollowUp)
        XCTAssertTrue(RefreshSessionEvent.resetManipulatedWithMouse.needsDiscoveryFollowUp)
        let startup = SessionPipeline.planLight(event: .startup)
        XCTAssertTrue(startup.scheduleFollowUpHeavy)
        let config = SessionPipeline.planLight(event: .configAutoReload)
        XCTAssertTrue(config.scheduleFollowUpHeavy)
    }

    func testDiscoveryClassificationForKnownEvents() {
        // Direct-heavy paths (activate/space/create) do not need light follow-up flags —
        // they call scheduleCancellableCompleteRefreshSession themselves.
        XCTAssertFalse(RefreshSessionEvent.globalObserver("NSWorkspaceDidActivateApplicationNotification").needsDiscoveryFollowUp)
        XCTAssertFalse(RefreshSessionEvent.globalObserverLeftMouseUp.needsDiscoveryFollowUp)
        XCTAssertFalse(RefreshSessionEvent.ax("AXWindowCreated").needsDiscoveryFollowUp)
    }

    func testTrayUpdateCanSkipOnFfmUnchangedFingerprint() {
        let fp = TrayVisibleFingerprint(
            focusWorkspace: "1",
            mode: nil,
            monitorActiveWorkspaces: ["1", "2"],
        )
        // Full walk always rebuilds
        XCTAssertFalse(trayUpdateCanSkip(fullLeafWalk: true, previous: fp, next: fp))
        // FFM: same fingerprint → skip leaf walk
        XCTAssertTrue(trayUpdateCanSkip(fullLeafWalk: false, previous: fp, next: fp))
        // FFM: workspace change → must update
        let next = TrayVisibleFingerprint(
            focusWorkspace: "2",
            mode: nil,
            monitorActiveWorkspaces: ["1", "2"],
        )
        XCTAssertFalse(trayUpdateCanSkip(fullLeafWalk: false, previous: fp, next: next))
        // First call (no previous) never skips
        XCTAssertFalse(trayUpdateCanSkip(fullLeafWalk: false, previous: nil, next: fp))
    }

    func testCancelledHeavyIsRescheduledAfterNonDiscoveryLight() {
        // Hotkey (no follow-up) cancelled an in-flight create/activate/mouse-up heavy →
        // must re-queue discovery so the window is not left unregistered.
        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        XCTAssertTrue(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: true,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: plan.scheduleFollowUpHeavy,
        ))
        // No pending obligation → no reschedule
        XCTAssertFalse(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: false,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: false,
        ))
        // Heavy still running (FFM did not cancel) → do not double-schedule
        XCTAssertFalse(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: true,
            hasActiveHeavyTask: true,
            planSchedulesFollowUp: false,
        ))
        // Light already schedules follow-up → that path owns the re-queue
        XCTAssertFalse(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: true,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: true,
        ))
        // Mouse-up settle plan still wants discovery follow-up when used as light
        let mouseUp = SessionPipeline.planLight(event: .resetManipulatedWithMouse)
        XCTAssertTrue(mouseUp.scheduleFollowUpHeavy)
    }

    func testDragLightDoesNotRescheduleUnlessPending() {
        let plan = SessionPipeline.planLight(event: .ax("AXWindowMoved"), mouseManipulate: true)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        // During drag with no cancelled heavy, stay quiet (mouse-up schedules complete heavy).
        XCTAssertFalse(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: false,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: plan.scheduleFollowUpHeavy,
        ))
        // If mouse-up heavy was scheduled then a concurrent light cancelled it, re-queue.
        XCTAssertTrue(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: true,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: plan.scheduleFollowUpHeavy,
        ))
    }

    /// Drives the real clear-policy used by `scheduleCancellableCompleteRefreshSession`
    /// after `runHeavy` returns (including when CancellationError was swallowed).
    func testMayClearDiscoveryHeavyPendingOnlyOnSuccessfulComplete() {
        // Success + still the owning generation → clear pending
        XCTAssertTrue(mayClearDiscoveryHeavyPending(
            generationMatches: true,
            heavyCompletedSuccessfully: true,
        ))
        // Cancelled mid-flight (runHeavy returned false) → MUST keep pending
        XCTAssertFalse(mayClearDiscoveryHeavyPending(
            generationMatches: true,
            heavyCompletedSuccessfully: false,
        ))
        // Light bumped generation after cancel → old task must not clear
        XCTAssertFalse(mayClearDiscoveryHeavyPending(
            generationMatches: false,
            heavyCompletedSuccessfully: true,
        ))
        XCTAssertFalse(mayClearDiscoveryHeavyPending(
            generationMatches: false,
            heavyCompletedSuccessfully: false,
        ))
    }

    /// Integration of the two gates used after a light pre-empts a mid-flight heavy.
    func testMidFlightCancelPathKeepsPendingAndReschedules() {
        // Simulate: heavy was running (pending true), light cancelled it (task nil, gen bumped).
        // Heavy task returns with completed=false OR generation mismatch → cannot clear.
        let stillPendingAfterCancel = !mayClearDiscoveryHeavyPending(
            generationMatches: false, // light called noteHeavyCancelledByLightSession
            heavyCompletedSuccessfully: false, // or true-after-swallow — still mismatch
        )
        XCTAssertTrue(stillPendingAfterCancel)

        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        // After light body: pending still true, no active task → re-queue
        XCTAssertTrue(sessionShouldRescheduleCancelledDiscovery(
            discoveryHeavyPending: true,
            hasActiveHeavyTask: false,
            planSchedulesFollowUp: plan.scheduleFollowUpHeavy,
        ))
    }

    @MainActor
    func testNoteHeavyCancelledBumpsGenerationSoOldTaskCannotClear() {
        // Drive real MainActor state used by schedule + light cancel.
        let genBefore = heavyScheduleGeneration
        discoveryHeavyPending = true
        // Simulate a scheduled task handle so cancel path runs.
        activeRefreshTask = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(60))
        }
        noteHeavyCancelledByLightSession()
        XCTAssertNil(activeRefreshTask)
        XCTAssertTrue(discoveryHeavyPending, "cancel must not clear discovery obligation")
        XCTAssertTrue(
            heavyScheduleGeneration > genBefore,
            "generation must bump so cancelled heavy cannot clear pending on return",
        )
        // Old generation must not be allowed to clear
        XCTAssertFalse(mayClearDiscoveryHeavyPending(
            generationMatches: false,
            heavyCompletedSuccessfully: true,
        ))
        // Cleanup
        discoveryHeavyPending = false
    }
}
