@testable import AppBundle
import Common
import XCTest

@MainActor
final class I3GapsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetRuntimeGapsOverrides()
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 5, bottom: 5, top: 5, right: 5))
    }

    override func tearDown() async throws { resetRuntimeGapsOverrides() }

    func testRuntimeGapsCommandCurrentAndAll() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run("gaps inner current plus 6")
        assertEquals(ws.resolvedGaps.inner.horizontal, 16)
        try await HeadlessHarness.run("gaps horizontal current set 0")
        assertEquals(ws.resolvedGaps.outer.left, 0)
        assertEquals(ws.resolvedGaps.outer.top, 5) // vertical untouched
        try await HeadlessHarness.run("gaps outer all toggle 20")
        assertEquals(Workspace.get(byName: "other").resolvedGaps.outer.top, 0) // 5 → toggled off
        let left = try XCTUnwrap(Window.get(byId: 1) as? TestWindow).laidOutRect!
        assertEquals(left.topLeftX, 0, additionalMsg: "outer gap toggled off on the edge")
    }

    func testSmartGapsDropAllGapsForASingleTile() async throws {
        config.smartGaps = true
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        try await ws.layoutWorkspace()
        assertEquals(w1.laidOutRect?.topLeftX, 0)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await ws.layoutWorkspace()
        assertEquals(w1.laidOutRect?.topLeftX, 5)
    }
}

@MainActor
final class I3RuleRetryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTitleRuleThatDidNotMatchAtMapTimeRunsWhenTheTitleChanges() async throws {
        let parsed = parseConfig("""
            [[on-window-detected]]
            if.window-title-regex-substring = 'Inbox'
            run = 'layout floating'
            """)
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
        config.onWindowDetected = parsed.config.onWindowDetected
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        w.titleForTest = "Loading…"
        await tryOnWindowDetected(w)
        XCTAssertTrue(w.parent is TilingContainer)
        XCTAssertTrue(w.hasPendingTitleRules)

        w.titleForTest = "Inbox - Mail"
        await onWindowTitleChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, w)
        XCTAssertTrue(w.isFloating, "the rule runs once the title matches")
        XCTAssertFalse(w.hasPendingTitleRules, "and never again for this window")
    }
}

@MainActor
final class I3TabbedStackedTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.accordionMode = .i3
    }

    private func group(_ orientation: Orientation, _ n: UInt32) -> [TestWindow] {
        let ws = focus.workspace
        let c = TilingContainer(parent: ws.rootTilingContainer, adaptiveWeight: 1, orientation, .accordion, index: INDEX_BIND_LAST)
        return (1 ... n).map { TestWindow.new(id: $0, parent: c) }
    }

    func testTabbedMembersFillTheContainerBelowOneTabRow() async throws {
        let ws = focus.workspace
        let windows = group(.h, 3)
        try await ws.layoutWorkspace()
        let frames = windows.map { $0.laidOutRect! }
        XCTAssertTrue(frames.allSatisfy { $0 == frames[0] }, "every tab has the same, full frame")
        assertEquals(frames[0].topLeftY, ws.tilingRect.topLeftY + i3TitleBandRowHeight)
        assertEquals(frames[0].width, ws.tilingRect.width)
    }

    func testStackedMembersSitBelowOneTitleRowPerMember() async throws {
        let ws = focus.workspace
        let windows = group(.v, 3)
        try await ws.layoutWorkspace()
        assertEquals(windows[2].laidOutRect!.topLeftY, ws.tilingRect.topLeftY + 3 * i3TitleBandRowHeight)
    }

    func testPeekModeUnchanged() async throws {
        config.accordionMode = .peek
        let ws = focus.workspace
        let windows = group(.h, 2)
        try await ws.layoutWorkspace()
        XCTAssertNotEqual(windows[0].laidOutRect, windows[1].laidOutRect, "peek offsets members")
    }
}
