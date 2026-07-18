@testable import AppBundle
import Common
import XCTest

/// Policy tests for SessionPipeline.Plan — the phase *order* is enforced by construction in
/// SessionPipeline.swift; these tests lock the load-bearing knobs (query-only, frames-written,
/// light→heavy follow-up) so refactors cannot silently reintroduce session-cost or lag bugs.
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

    func testLightMutatingPlanLayoutsAndSchedulesHeavy() {
        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertTrue(plan.clearFramesWritten)
        XCTAssertTrue(plan.layout)
        XCTAssertTrue(plan.scheduleFollowUpHeavy)
        XCTAssertFalse(plan.discoverWindows)
    }

    func testLightQueryOnlySkipsLayoutAndHeavy() {
        // echo is query-only (CmdKind.isQueryOnly) — no layout / no follow-up heavy
        let event = RefreshSessionEvent.socketServer(TrueCmdArgs(rawArgs: []))
        XCTAssertTrue(event.isQueryOnly)
        let plan = SessionPipeline.planLight(event: event)
        XCTAssertTrue(plan.clearFramesWritten)
        XCTAssertFalse(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
    }

    func testFocusFollowsMouseSkipsLayoutAndHeavy() {
        let plan = SessionPipeline.planLight(event: .focusFollowsMouse)
        XCTAssertFalse(plan.layout)
        XCTAssertFalse(plan.scheduleFollowUpHeavy)
        // High-frequency hover must not thrash borders/status bar/CPU sampling every move.
        XCTAssertFalse(plan.clearFramesWritten)
        XCTAssertFalse(plan.sideUiBorders)
        XCTAssertTrue(plan.sideUiTray)
    }

    func testHotkeyLightStillRunsSideUi() {
        let plan = SessionPipeline.planLight(event: .hotkeyBinding)
        XCTAssertTrue(plan.sideUiBorders)
        XCTAssertTrue(plan.sideUiTray)
        XCTAssertTrue(plan.clearFramesWritten)
    }
}
