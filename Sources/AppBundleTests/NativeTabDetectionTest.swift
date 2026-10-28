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

    // MARK: - tabEvidence: frames AeroSpace produced itself are not evidence of a tab group

    func testCornerParkedFramesAreNotTabEvidence() {
        // Two equal-weight tiles of one app hidden in the same off-screen corner share a frame
        // exactly (hideInCorner is a position-only write to one point). That is AeroSpace's own
        // parking, not a tab group — treating it as one yanked the higher id out of tiling on the
        // next workspace switch and re-inserted it beside the MRU window: shuffled tiles
        let monitor = rect(0, 0, 2560, 1440)
        let parked = rect(2559, 1439, 1264, 1400) // top-left at the monitor's bottom-right corner
        let evidence = NativeTabDetection.tabEvidence(
            [(1, 10), (1, 20)],
            monitorRect: monitor,
            frameOf: { _ in parked },
            isOnScreen: { _ in false },
        )
        XCTAssertTrue(evidence.isEmpty)
        XCTAssertTrue(NativeTabDetection.parkedSiblingIds(evidence).isEmpty)
    }

    func testTwoOnScreenWindowsSharingAFrameAreNotATabGroup() {
        // macOS orders background tabs out. Two on-screen same-app windows at one frame are an app
        // opening a new window exactly on top of its last one: both must tile
        let monitor = rect(0, 0, 2560, 1440)
        let shared = rect(100, 100, 800, 600)
        let evidence = NativeTabDetection.tabEvidence(
            [(1, 10), (1, 20)],
            monitorRect: monitor,
            frameOf: { _ in shared },
            isOnScreen: { _ in true },
        )
        XCTAssertTrue(NativeTabDetection.parkedSiblingIds(evidence).isEmpty)
    }

    func testTabGroupHasOneMemberOnScreen() {
        // The real case: same app, same frame, only the active tab on screen → higher id parks.
        // Holds regardless of which member is the active (on-screen) tab
        let monitor = rect(0, 0, 2560, 1440)
        let shared = rect(100, 100, 800, 600)
        for active: UInt32 in [10, 20] {
            let evidence = NativeTabDetection.tabEvidence(
                [(1, 10), (1, 20), (1, 30)],
                monitorRect: monitor,
                frameOf: { _ in shared },
                isOnScreen: { $0 == active },
            )
            XCTAssertEqual(NativeTabDetection.parkedSiblingIds(evidence), [20, 30])
        }
    }

    func testUnreadableFrameIsDropped() {
        let monitor = rect(0, 0, 2560, 1440)
        let evidence = NativeTabDetection.tabEvidence(
            [(1, 10), (1, 20)],
            monitorRect: monitor,
            frameOf: { $0 == 10 ? rect(0, 0, 100, 100) : nil },
            isOnScreen: { _ in false },
        )
        XCTAssertEqual(evidence.map(\.id), [10])
    }
}
