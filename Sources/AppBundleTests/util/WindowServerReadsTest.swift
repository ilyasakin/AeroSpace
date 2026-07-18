@testable import AppBundle
import XCTest

/// Fixed WindowServer double — no SkyLight / CGWindowList.
private final class FakeWindowServerReads: WindowServerReadPort {
    var boundsById: [UInt32: Rect] = [:]
    var snapshot = OnScreenWindowSnapshot(levels: [:], normalStack: [])
    var boundsCallCount = 0
    var snapshotCallCount = 0

    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? {
        boundsCallCount += 1
        return boundsById[windowId]
    }

    func onScreenSnapshot() -> OnScreenWindowSnapshot {
        snapshotCallCount += 1
        return snapshot
    }
}

@MainActor
final class WindowServerReadsTest: XCTestCase {
    override func tearDown() {
        WindowServerReads.install(nil)
        super.tearDown()
    }

    // MARK: resolveFrameRead (production decision table)

    func testStaleWithLastAppliedPrefersLastApplied() {
        let applied = Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 400)
        let r = resolveFrameRead(
            windowId: 1,
            lastApplied: applied,
            mayBeStale: true,
            serverBounds: { _ in
                XCTFail("server must not be consulted when stale + lastApplied")
                return nil
            },
        )
        XCTAssertEqual(r, .lastApplied(applied))
    }

    func testStaleWithoutLastAppliedNeedsAx() {
        let r = resolveFrameRead(
            windowId: 1,
            lastApplied: nil,
            mayBeStale: true,
            serverBounds: { _ in
                XCTFail("server must not be consulted when stale without lastApplied")
                return Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1)
            },
        )
        XCTAssertEqual(r, .needAx)
    }

    func testFreshUsesServerBounds() {
        let ws = Rect(topLeftX: 5, topLeftY: 6, width: 7, height: 8)
        let r = resolveFrameRead(
            windowId: 42,
            lastApplied: nil,
            mayBeStale: false,
            serverBounds: { id in
                XCTAssertEqual(id, 42)
                return ws
            },
        )
        XCTAssertEqual(r, .windowServer(ws))
    }

    func testFreshServerMissNeedsAx() {
        let r = resolveFrameRead(
            windowId: 1,
            lastApplied: Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1),
            mayBeStale: false,
            serverBounds: { _ in nil },
        )
        // lastApplied is only used on the stale path; fresh miss goes to AX
        XCTAssertEqual(r, .needAx)
    }

    // MARK: resolveBorderRect (must track live drag)

    func testBorderFreshPrefersLiveOverLastApplied() {
        // Regression: unconditional lastApplied froze borders on the layout tile during drag
        let applied = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        let live = Rect(topLeftX: 50, topLeftY: 60, width: 400, height: 400)
        let r = resolveBorderRect(
            lastApplied: applied,
            mayBeStale: false,
            liveBounds: live,
            stackRect: applied,
        )
        XCTAssertEqual(r, live)
    }

    func testBorderStalePrefersLastApplied() {
        let applied = Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 400)
        let live = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 400) // lagging WS
        let r = resolveBorderRect(
            lastApplied: applied,
            mayBeStale: true,
            liveBounds: live,
            stackRect: nil,
        )
        XCTAssertEqual(r, applied)
    }

    func testBorderFallsBackStackThenLastApplied() {
        let applied = Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4)
        let stack = Rect(topLeftX: 5, topLeftY: 6, width: 7, height: 8)
        XCTAssertEqual(
            resolveBorderRect(lastApplied: applied, mayBeStale: false, liveBounds: nil, stackRect: stack),
            stack,
        )
        XCTAssertEqual(
            resolveBorderRect(lastApplied: applied, mayBeStale: false, liveBounds: nil, stackRect: nil),
            applied,
        )
    }

    // MARK: mergeFrameWrite (resize → center command chains)

    func testMergeFrameWriteSizeOnlyThenPositionOnly() {
        let tile = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
        // resize smart 60% of 1920x1080 → 1152×648
        let afterResize = mergeFrameWrite(
            previous: tile,
            topLeft: nil,
            size: CGSize(width: 1152, height: 648),
        )
        XCTAssertEqual(afterResize, Rect(topLeftX: 0, topLeftY: 0, width: 1152, height: 648))
        // center-window only passes origin
        let afterCenter = mergeFrameWrite(
            previous: afterResize,
            topLeft: CGPoint(x: (1920 - 1152) / 2, y: (1080 - 648) / 2),
            size: nil,
        )
        XCTAssertEqual(afterCenter?.width, 1152)
        XCTAssertEqual(afterCenter?.height, 648)
        XCTAssertEqual(afterCenter?.topLeftX, (1920 - 1152) / 2)
        XCTAssertEqual(afterCenter?.topLeftY, (1080 - 648) / 2)
    }

    func testMergeFrameWritePartialWithoutPrevious() {
        XCTAssertNil(mergeFrameWrite(previous: nil, topLeft: nil, size: CGSize(width: 10, height: 10)))
        XCTAssertNil(mergeFrameWrite(previous: nil, topLeft: .zero, size: nil))
        let both = mergeFrameWrite(previous: nil, topLeft: CGPoint(x: 1, y: 2), size: CGSize(width: 3, height: 4))
        XCTAssertEqual(both, Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4))
    }

    // MARK: Injectable port (real WindowServerReads entry point)

    func testInstallFakeBoundsUsedByCurrentPort() {
        let fake = FakeWindowServerReads()
        let fixed = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)
        fake.boundsById[7] = fixed
        WindowServerReads.install(fake)

        let got = WindowServerReads.current.windowBounds(windowId: 7, forOverlay: false)
        XCTAssertEqual(got, fixed)
        XCTAssertEqual(fake.boundsCallCount, 1)

        // resolveFrameRead wired the same way MacWindow does
        let resolution = resolveFrameRead(
            windowId: 7,
            lastApplied: nil,
            mayBeStale: false,
            serverBounds: { WindowServerReads.current.windowBounds(windowId: $0, forOverlay: false) },
        )
        XCTAssertEqual(resolution, .windowServer(fixed))
    }

    func testInstallFakeSnapshotUsedByOnScreenWindowSnapshot() {
        let fake = FakeWindowServerReads()
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        fake.snapshot = OnScreenWindowSnapshot(
            levels: [9: .normalWindow, 10: .alwaysOnTopWindow],
            normalStack: [(9, rect)],
        )
        WindowServerReads.install(fake)

        // Production getWindowLevel / borders go through this free function
        let snap = onScreenWindowSnapshot()
        XCTAssertEqual(snap.levels[9], .normalWindow)
        XCTAssertEqual(snap.levels[10], .alwaysOnTopWindow)
        XCTAssertEqual(snap.normalStack.count, 1)
        XCTAssertEqual(snap.normalStack[0].id, 9)
        XCTAssertEqual(snap.normalStack[0].rect, rect)
        // getWindowLevel uses the same snapshot entry point (another call)
        XCTAssertEqual(getWindowLevel(for: 10), .alwaysOnTopWindow)
        _ = onScreenWindowSnapshot()
        // 1 snap + 1 getWindowLevel + 1 snap = 3; no real CGWindowList involved
        XCTAssertEqual(fake.snapshotCallCount, 3)
        XCTAssertGreaterThan(fake.snapshotCallCount, 0)
    }

    func testInstallNilRestoresProductionPort() {
        let fake = FakeWindowServerReads()
        WindowServerReads.install(fake)
        WindowServerReads.install(nil)
        // Production type after reset
        XCTAssertTrue(WindowServerReads.current is ProductionWindowServerReads)
    }
}
