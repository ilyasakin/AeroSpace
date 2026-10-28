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

    // MARK: Window.getAxRect — what layout and commands read

    @MainActor
    func testRightAfterOurWriteTheWriteIsTheAnswer() async throws {
        setUpWorkspacesForTests()
        let fake = FakeWindowServerReads()
        let lagging = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        fake.boundsById[1] = lagging
        WindowServerReads.install(fake)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let target = Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 400)
        window.setAxFrame(target.topLeftCorner, CGSize(width: target.width, height: target.height))
        let read = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(read, target, "WindowServer may still show the pre-write frame")
    }

    @MainActor
    func testAtRestWindowServerIsTheAnswer() async throws {
        setUpWorkspacesForTests()
        let fake = FakeWindowServerReads()
        let live = Rect(topLeftX: 5, topLeftY: 6, width: 700, height: 800)
        fake.boundsById[1] = live
        WindowServerReads.install(fake)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1))
        let read = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(read, live)
    }

    @MainActor
    func testWithoutWindowServerTheAppIsAsked() async throws {
        setUpWorkspacesForTests() // the default test port: no WindowServer data
        let ax = Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: ax)
        let read = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(read, ax)
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

    func testInstallNilRestoresDefaultPort() {
        let fake = FakeWindowServerReads()
        WindowServerReads.install(fake)
        WindowServerReads.install(nil)
        // Default after reset. Under test the default is the empty WindowServer (Headless), never
        // the production port: test ids must not resolve to the user's real windows.
        XCTAssertTrue(WindowServerReads.current is NullWindowServerReads)
    }
}
