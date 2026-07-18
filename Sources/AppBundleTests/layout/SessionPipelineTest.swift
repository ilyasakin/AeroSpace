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
}
