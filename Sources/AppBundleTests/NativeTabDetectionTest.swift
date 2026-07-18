@testable import AppBundle
import Common
import XCTest

final class NativeTabDetectionTest: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Rect {
        Rect(topLeftX: x, topLeftY: y, width: w, height: h)
    }

    func testLowestIdIsRepresentativeRestParked() {
        // Same app, same frame, three tabs -> lowest id (10) is the tiled representative; 20 & 30 park
        let f = rect(100, 100, 800, 600)
        let group: [(pid: Int32, id: UInt32, frame: Rect)] = [(1, 30, f), (1, 10, f), (1, 20, f)]
        XCTAssertEqual(NativeTabDetection.parkedSiblingIds(group), [20, 30])
    }

    func testDifferentFramesAreNotGrouped() {
        // Tiled windows never share a frame -> not a tab group -> nothing parked
        let group: [(pid: Int32, id: UInt32, frame: Rect)] = [
            (1, 10, rect(0, 0, 100, 100)), (1, 20, rect(200, 0, 100, 100)),
        ]
        XCTAssertTrue(NativeTabDetection.parkedSiblingIds(group).isEmpty)
    }

    func testDifferentAppsSameFrameNotGrouped() {
        // Same frame but different pids (e.g. a floating window over another app) -> not tabs
        let f = rect(0, 0, 100, 100)
        let group: [(pid: Int32, id: UInt32, frame: Rect)] = [(1, 10, f), (2, 20, f)]
        XCTAssertTrue(NativeTabDetection.parkedSiblingIds(group).isEmpty)
    }

    func testSingleWindowNeverParked() {
        XCTAssertTrue(NativeTabDetection.parkedSiblingIds([(1, 10, rect(0, 0, 1, 1))]).isEmpty)
    }

    func testTwoAppsEachTabbedIndependently() {
        // App 1 tabs share frame F1; app 2 tabs share frame F2 -> each parks its own higher-id member
        let f1 = rect(0, 0, 500, 500)
        let f2 = rect(600, 0, 500, 500)
        let group: [(pid: Int32, id: UInt32, frame: Rect)] = [(1, 10, f1), (1, 40, f1), (2, 20, f2), (2, 5, f2)]
        XCTAssertEqual(NativeTabDetection.parkedSiblingIds(group), [40, 20])
    }

    func testSubPixelJitterStillGroups() {
        // SkyLight sub-pixel jitter must not defeat the exact-frame match
        let group: [(pid: Int32, id: UInt32, frame: Rect)] = [
            (1, 10, rect(100, 100, 800, 600)), (1, 20, rect(100.4, 99.8, 800.5, 600.2)),
        ]
        XCTAssertEqual(NativeTabDetection.parkedSiblingIds(group), [20])
        XCTAssertFalse(NativeTabDetection.rectsApproximatelyEqual(rect(100, 100, 800, 600), rect(120, 100, 800, 600)))
    }
}
