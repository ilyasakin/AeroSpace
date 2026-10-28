@testable import AppBundle
import Common
import XCTest

final class AxFrameWritePlanTest: XCTestCase {
    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Rect { Rect(topLeftX: x, topLeftY: y, width: w, height: h) }

    func testHideCornerParkingIsPositionOnly() {
        // Was size + position + size (3 AX messages) for a position-only intent
        let plan = planAxFrameWrite(previous: r(0, 0, 800, 600), previousInFlight: false, target: r(2559, 1439, 800, 600), crossesMonitor: false)
        XCTAssertEqual(plan, AxFrameWritePlan(size: false, position: true, trailingSize: false))
    }

    func testResizeInPlaceIsSizeOnly() {
        let plan = planAxFrameWrite(previous: r(0, 0, 800, 600), previousInFlight: false, target: r(0, 0, 900, 600), crossesMonitor: false)
        XCTAssertEqual(plan, AxFrameWritePlan(size: true, position: false, trailingSize: false))
    }

    func testBackFromTheHideCornerOrAcrossMonitorsIsAFullWrite() {
        // The window may have been clamped/resized while parked: never trust the believed size
        let plan = planAxFrameWrite(previous: r(2559, 1439, 800, 600), previousInFlight: false, target: r(0, 0, 800, 600), crossesMonitor: true)
        XCTAssertEqual(plan, .full)
    }

    func testTrailingSizeOnlyAcrossMonitorsOrWhenGrowingWhileMoving() {
        let shrinks = planAxFrameWrite(previous: r(0, 0, 800, 600), previousInFlight: false, target: r(100, 0, 700, 600), crossesMonitor: false)
        XCTAssertFalse(shrinks.trailingSize)
        let cross = planAxFrameWrite(previous: r(0, 0, 800, 600), previousInFlight: false, target: r(3000, 0, 900, 600), crossesMonitor: true)
        XCTAssertEqual(cross, .full)
    }

    /// ws 2: a bottom-right tile going fullscreen. The size, applied at the old origin, is clamped
    /// to what fits from there (2560-1288 x 1440-740): it must be sent again after the move
    func testGrowingWhileMovingResendsTheSizeAfterTheMove() {
        let plan = planAxFrameWrite(previous: r(1288, 740, 386, 334), previousInFlight: false, target: r(16, 40, 2528, 1384), crossesMonitor: false)
        XCTAssertEqual(plan, AxFrameWritePlan(size: true, position: true, trailingSize: true))
    }

    /// A float hanging past the right/bottom edge, shrunk and moved: the size, applied first at the
    /// old origin, is clamped to the part that fits there
    func testShrinkingWhileMovingOffAnOverhangResendsTheSize() {
        let plan = planAxFrameWrite(previous: r(1900, 800, 1200, 900), previousInFlight: false, target: r(600, 300, 1000, 700), crossesMonitor: false, previousOverhangsScreen: true)
        XCTAssertTrue(plan.trailingSize)
    }

    /// Asked y=1089, it sits at 1090: the position is not re-sent on every layout
    func testAWindowSettledAPixelOffIsNotMovedAgain() {
        let plan = planAxFrameWrite(previous: r(1288, 1090, 1256, 334), previousInFlight: false, target: r(1288, 1089, 1256, 334), crossesMonitor: false)
        XCTAssertFalse(plan.size)
        XCTAssertTrue(plan.position, "nothing changed: the cheap re-assert")
        let moved = planAxFrameWrite(previous: r(1288, 1090, 1256, 334), previousInFlight: false, target: r(1288, 1089, 1200, 334), crossesMonitor: false)
        XCTAssertEqual(moved, AxFrameWritePlan(size: true, position: false, trailingSize: false), "a resize doesn't drag a 1px move along")
    }

    func testUnknownBeliefOrInFlightWriteSendsEverything() {
        XCTAssertEqual(planAxFrameWrite(previous: nil, previousInFlight: false, target: r(0, 0, 1, 1), crossesMonitor: false), .full)
        // The new job cancels the in-flight one, so whatever it carried must be resent
        XCTAssertEqual(planAxFrameWrite(previous: r(0, 0, 800, 600), previousInFlight: true, target: r(10, 0, 800, 600), crossesMonitor: false), .full)
    }
}

/// Intent (`desiredRect`) and knowledge (`FrameRecord`) are separate. When they aliased one field,
/// layout recorded the tile rect before writing, the planner read it back as "already there" and
/// sent position only — a window back from the hide corner at a stale size never got resized.
@MainActor
final class IntentVsKnowledgeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Rect { Rect(topLeftX: x, topLeftY: y, width: w, height: h) }

    func testRecordingLayoutIntentLeavesKnowledgeAlone() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.frame.adopt(r(2559, 1412, 1675, 1383)) // parked in the corner, app shrank it earlier
        window.desiredRect = r(16, 40, 2528, 1383)
        XCTAssertEqual(window.knownFrame, r(2559, 1412, 1675, 1383))
        window.frame.forget()
        XCTAssertEqual(window.desiredRect, r(16, 40, 2528, 1383), "dropping knowledge must not drop intent")
    }

    func testUnparkAtStaleSizeWritesTheSize() {
        let parked = r(2559, 1412, 1675, 1383)
        let tile = r(16, 40, 2528, 1383)
        XCTAssertTrue(planAxFrameWrite(previous: parked, previousInFlight: false, target: tile, crossesMonitor: true).size)
        XCTAssertTrue(planAxFrameWrite(previous: parked, previousInFlight: false, target: tile, crossesMonitor: false).size)
    }
}

final class TileSpanFloorTest: XCTestCase {
    func testCollapsedTilesAreRaisedToTheFloor() {
        // The ws-2 tree: two windows squeezed to 5.5px beside a 664px sibling
        let out = flooredTileSpans([664.5, 5.5, 5.5], span: 675.5, floor: 50)
        XCTAssertEqual(out[1], 50)
        XCTAssertEqual(out[2], 50)
        XCTAssertEqual(out.reduce(0, +), 675.5, accuracy: 0.01)
    }

    func testZeroWeightContainerGetsASpan() {
        let out = flooredTileSpans([2528, 0], span: 2528, floor: 50)
        XCTAssertEqual(out[1], 50)
        XCTAssertEqual(out[0], 2478, accuracy: 0.01)
    }

    func testHealthySpansAreUntouchedAndTightSpaceSplitsEvenly() {
        assertEquals(flooredTileSpans([500, 500], span: 1000, floor: 50), [500, 500])
        assertEquals(flooredTileSpans([0, 0], span: 60, floor: 30), [30, 30])
    }
}
