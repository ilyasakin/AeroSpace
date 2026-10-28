@testable import AppBundle
import Common
import XCTest

/// The frame record inside the real pipeline, against the simulated desktop
@MainActor
final class FrameRecordIntegrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws {
        FrameRecord.appSizeSettleSeconds = 1
        WindowServerReads.install(nil)
    }

    func testAnAppThatCapsItsSizeIsAnsweredNotFought() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        FrameRecord.appSizeSettleSeconds = 0
        let root = focus.workspace.rootTilingContainer
        let capped = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        SimulatedMacOS.shared.maxSize[1] = CGSize(width: 400, height: 10_000)
        try await HeadlessHarness.run("balance-sizes")
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertNil(capped.learnedMaxSize, "one answer is not a cap")
        // A different request, the same answer: that is a maximum
        let third = TestWindow.new(id: 3, parent: root)
        try await HeadlessHarness.run("balance-sizes")
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertEqual(capped.learnedMaxSize?.width, 400)
        XCTAssertEqual(capped.laidOutRect?.width, 400)
        XCTAssertGreaterThan(third.laidOutRect?.width ?? 0, 640, "siblings get the space it can't use")
        let writesToCapped = SimulatedMacOS.shared.frameWrites.filter { $0.windowId == 1 }.count
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertEqual(SimulatedMacOS.shared.frameWrites.filter { $0.windowId == 1 }.count, writesToCapped, "no re-asking")
    }

    /// A learned cap must be able to relax: the capped tile is never asked for more, so it is never
    /// seen larger. A changed slot asks again; a still-capped app re-confirms on its first answer
    func testALearnedCapIsAskedAgainWhenItsSlotChanges() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        FrameRecord.appSizeSettleSeconds = 0
        let root = focus.workspace.rootTilingContainer
        let capped = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        SimulatedMacOS.shared.maxSize[1] = CGSize(width: 400, height: 10_000)
        try await HeadlessHarness.run(["balance-sizes", "balance-sizes"])
        let third = TestWindow.new(id: 3, parent: root)
        try await HeadlessHarness.run(["balance-sizes", "balance-sizes"])
        XCTAssertEqual(capped.learnedMaxSize?.width, 400)

        // Still capped: the slot changes (a sibling closed), it is asked once and re-confirms
        third.garbageCollect(skipClosedWindowsCache: true)
        try await HeadlessHarness.run(["balance-sizes", "balance-sizes"])
        XCTAssertEqual(capped.learnedMaxSize?.width, 400, "re-confirmed")
        XCTAssertEqual(capped.laidOutRect?.width, 400)

        // The app's limit is gone: the next changed slot finds it out
        SimulatedMacOS.shared.maxSize[1] = nil
        TestWindow.new(id: 4, parent: root)
        try await HeadlessHarness.run(["balance-sizes", "balance-sizes"])
        XCTAssertNil(capped.learnedMaxSize)
        XCTAssertGreaterThan(capped.laidOutRect?.width ?? 0, 600)
    }

    /// Video keeps its aspect ratio: its height follows the width it is given. That is not a
    /// maximum — capping it left the window short and centred once its tile changed
    func testAnAspectLockedAppIsNotCapped() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        FrameRecord.appSizeSettleSeconds = 0
        let root = focus.workspace.rootTilingContainer
        let video = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        SimulatedMacOS.shared.aspectRatio[1] = 16.0 / 9
        try await HeadlessHarness.run("balance-sizes")
        try await HeadlessHarness.run("balance-sizes")
        TestWindow.new(id: 3, parent: root)
        try await HeadlessHarness.run("balance-sizes")
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertNil(video.learnedMaxSize)
    }

    /// Slack (Electron) answers a resize with its old size and gets there a moment later. That
    /// first answer used to become a cap, and a lone Slack tile sat centred at 2053 of 2528 px.
    func testAnAppThatResizesLateIsNotCapped() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        FrameRecord.appSizeSettleSeconds = 0
        let slack = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 1272, height: 900))
        SimulatedMacOS.shared.answersBeforeResizing = [1]
        try await HeadlessHarness.run("balance-sizes")
        guard case .appSized = slack.frame.phase else { return XCTFail("the old size was answered: \(slack.frame.phase)") }
        // WindowServer then reports it at the asked frame: our write, landed late
        XCTAssertTrue(slack.isOwnFrameWrite())
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertNil(slack.learnedMaxSize)
        XCTAssertEqual(slack.laidOutRect?.width, focus.workspace.desiredRect?.width, "a lone tile fills the workspace")
    }

    func testOurOwnWriteComingBackIsRecognised() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        try await HeadlessHarness.run("balance-sizes")
        guard case .known(let landed) = window.frame.phase else { return XCTFail("\(window.frame.phase)") }
        XCTAssertEqual(landed, window.laidOutRect)
        // The simulator has no WindowServer: a recent write is trusted
        XCTAssertTrue(window.isOwnFrameWrite())
    }

    func testAnExternalMoveIsTakenAsTheWindowsNewFrame() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let moved = Rect(topLeftX: 300, topLeftY: 200, width: 640, height: 480)
        XCTAssertEqual(window.frame.windowServerReported(moved, now: 100), .external)
        XCTAssertEqual(window.knownFrame, moved)
    }
}

@MainActor
final class MacosOwnedWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// A native-fullscreen window lives in its own Space: switching away from its workspace must
    /// not "park" it (TV's fullscreen window got a refused position write on every switch)
    func testANativeFullscreenWindowIsNeverParked() async throws {
        let ws1 = Workspace.get(byName: "1")
        TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws1.macOsNativeFullscreenWindowsContainer)
        _ = ws1.focusWorkspace()
        try await HeadlessHarness.run("workspace 2")
        try await HeadlessHarness.run("workspace 1")
        await HeadlessHarness.heavy()
        XCTAssertTrue(SimulatedMacOS.shared.frameWrites.filter { $0.windowId == 2 }.isEmpty)
        XCTAssertFalse(SimulatedMacOS.shared.frameWrites.filter { $0.windowId == 1 }.isEmpty, "the tile was parked and back")
    }
}
