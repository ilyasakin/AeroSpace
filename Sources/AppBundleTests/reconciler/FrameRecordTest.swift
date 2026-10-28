@testable import AppBundle
import Common
import XCTest

/// The per-window frame state machine. Each case is a scenario from a real trace that the old
/// timer heuristics got wrong at least once.
final class FrameRecordTest: XCTestCase {
    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Rect { Rect(topLeftX: x, topLeftY: y, width: w, height: h) }

    private let parked = Rect(topLeftX: 2559, topLeftY: 1412, width: 1675, height: 1383)
    private let tile = Rect(topLeftX: 16, topLeftY: 40, width: 2528, height: 1383)

    func testAWriteTheAppTakesLands() {
        var record = FrameRecord()
        _ = record.windowServerReported(parked, now: 0)
        let seq = record.wrote(tile, now: 0)
        XCTAssertEqual(record.bestKnown, tile, "in flight: the target is the best answer")
        XCTAssertEqual(record.appAnswered(seq: seq, reported: tile, now: 1), .landed)
        XCTAssertEqual(record.phase, .known(tile))
    }

    func testEveryReportWhileTheWriteIsInFlightIsOurs() {
        var record = FrameRecord()
        _ = record.wrote(tile, now: 0)
        // size applied at the old position, then moved: both intermediate frames are ours
        XCTAssertEqual(record.windowServerReported(r(2559, 1412, 2528, 1383), now: 0.01), .ownWrite)
        XCTAssertEqual(record.windowServerReported(r(16, 40, 1675, 1383), now: 0.02), .ownWrite)
    }

    func testAspectLockedAppAnswersWithItsOwnSize() {
        // Apple TV: asked 1256x1383, it keeps 16:9
        var record = FrameRecord()
        let target = r(1288, 40, 1256, 1383)
        let seq = record.wrote(target, now: 0)
        XCTAssertEqual(record.appAnswered(seq: seq, reported: r(1288, 40, 1255, 706), now: 1), .appSized(actual: r(1288, 40, 1255, 706)))
        XCTAssertEqual(record.bestKnown, r(1288, 40, 1255, 706), "borders and reads follow the app's answer")
        // Its own resize notification afterwards is not an outside change (that re-wrote the tile in a loop)
        XCTAssertEqual(record.windowServerReported(r(1288, 40, 1255, 706), now: 1.1), .ownWrite)
    }

    func testWindowServerCatchingUpAfterTheAnswerIsNotAMove() {
        var record = FrameRecord()
        _ = record.windowServerReported(parked, now: 0)
        let seq = record.wrote(tile, now: 0)
        _ = record.appAnswered(seq: seq, reported: tile, now: 1)
        // WindowServer still reports the pre-write frame, then half of it
        XCTAssertEqual(record.windowServerReported(parked, now: 1.05), .lagging)
        XCTAssertEqual(record.windowServerReported(r(16, 40, 1675, 1383), now: 1.1), .lagging)
        XCTAssertEqual(record.phase, .known(tile))
    }

    func testTheSameFrameLongAfterTheAnswerIsAMove() {
        var record = FrameRecord()
        _ = record.windowServerReported(parked, now: 0)
        let seq = record.wrote(tile, now: 0)
        _ = record.appAnswered(seq: seq, reported: tile, now: 1)
        XCTAssertEqual(record.windowServerReported(r(300, 200, 800, 600), now: 1.05), .external)
        XCTAssertEqual(record.phase, .known(r(300, 200, 800, 600)))
    }

    func testAnAnswerToAReplacedWriteIsIgnored() {
        var record = FrameRecord()
        let first = record.wrote(r(0, 0, 100, 100), now: 0)
        let second = record.wrote(tile, now: 0)
        XCTAssertEqual(record.appAnswered(seq: first, reported: r(0, 0, 100, 100), now: 1), .stale)
        XCTAssertTrue(record.isWriting)
        XCTAssertEqual(record.appAnswered(seq: second, reported: tile, now: 2), .landed)
    }

    func testAReplacingWriteKeepsTheOriginalPreWriteFrame() {
        var record = FrameRecord()
        _ = record.windowServerReported(parked, now: 0)
        _ = record.wrote(r(0, 0, 100, 100), now: 0) // never shown
        let seq = record.wrote(tile, now: 0)
        _ = record.appAnswered(seq: seq, reported: tile, now: 1)
        XCTAssertEqual(record.windowServerReported(parked, now: 1.01), .lagging, "lag of the frame before BOTH writes")
    }

    func testAMissedPositionIsNotBelieved() {
        var record = FrameRecord()
        let seq = record.wrote(tile, now: 0)
        XCTAssertEqual(record.appAnswered(seq: seq, reported: r(400, 300, 2528, 1383), now: 1), .missed)
        XCTAssertEqual(record.bestKnown, r(400, 300, 2528, 1383))
    }

    func testAnUnreadableAnswerDropsKnowledge() {
        var record = FrameRecord()
        let seq = record.wrote(tile, now: 0)
        XCTAssertEqual(record.appAnswered(seq: seq, reported: nil, now: 1), .missed)
        XCTAssertNil(record.bestKnown, "the next write must be a full one")
    }

    func testParkedWindowPulledBackByMacosIsOurs() {
        var record = FrameRecord()
        let seq = record.wrote(r(2559, 1439, 2528, 1383), now: 0)
        _ = record.appAnswered(seq: seq, reported: r(2559, 1412, 2528, 1383), now: 1)
        XCTAssertEqual(record.windowServerReported(r(2559, 1412, 2528, 1383), now: 2, isParkedOffScreen: true), .ownWrite)
    }

    func testWindowServerMayLagOnlyAroundAWrite() {
        var record = FrameRecord()
        XCTAssertFalse(record.windowServerMayLag(now: 0))
        let seq = record.wrote(tile, now: 0)
        XCTAssertTrue(record.windowServerMayLag(now: 0))
        _ = record.appAnswered(seq: seq, reported: tile, now: 1)
        XCTAssertTrue(record.windowServerMayLag(now: 1.2))
        XCTAssertFalse(record.windowServerMayLag(now: 2))
    }

    /// Closing the window or toggling native fullscreen cancels a write before it runs: no answer
    func testAWriteNobodyAnswersIsLostAfterATimeout() {
        var record = FrameRecord()
        _ = record.wrote(tile, now: 0)
        XCTAssertEqual(record.windowServerReported(r(300, 300, 800, 600), now: 0.5), .ownWrite, "still possibly ours")
        XCTAssertTrue(record.windowServerMayLag(now: 0.5))
        XCTAssertFalse(record.windowServerMayLag(now: 2))
        XCTAssertEqual(record.windowServerReported(r(300, 300, 800, 600), now: 2), .external, "lost: a real move")
        XCTAssertEqual(record.bestKnown, r(300, 300, 800, 600))
    }
}
