@testable import AppBundle
import Common
import XCTest

@MainActor
final class I3MarksAndCriteriaTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private var ws: Workspace { focus.workspace }
    private func tree() -> String { ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: "") }

    func testMarksAreUniqueAndAddable() async throws {
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await HeadlessHarness.run("mark a")
        try await HeadlessHarness.run("mark --add b")
        assertEquals(w1.marks, ["a", "b"])
        // Marking another window with "a" takes it away from 1 (i3 marks are unique)
        try await HeadlessHarness.run("mark --window-id 2 a")
        assertEquals(w1.marks, ["b"])
        assertEquals(w2.marks, ["a"])
        try await HeadlessHarness.run("mark --window-id 2 --toggle a")
        assertEquals(w2.marks, [])
        try await HeadlessHarness.run("unmark")
        assertEquals(w1.marks, [])
    }

    func testCriteriaPrefixTargetsMatchingWindows() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        w2.marks = ["music"]
        try await HeadlessHarness.run(#"[con_mark="music"] focus"#)
        assertEquals(focus.windowOrNil?.windowId, 2)
        try await HeadlessHarness.run("[con_id=1] focus")
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testCriteriaRunsTheCommandOncePerMatch() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        // TestApp's bundle id is bobko.AeroSpace.test-app — every window matches
        try await HeadlessHarness.run(#"[class="test-app$"] move-node-to-workspace other"#)
        assertEquals(Workspace.get(byName: "other").allLeafWindowsRecursive.count, 3)
    }

    func testCriteriaNativeSpellingAndErrors() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        let r = try await HeadlessHarness.run("criteria window-id=1 -- mark x")
        assertEquals(r.exitCode.rawValue, 0)
        assertEquals(Window.get(byId: 1)?.marks, ["x"])
        XCTAssertNotNil(parseCommand("criteria bogus=1 -- focus left").errorOrNil)
        XCTAssertNotNil(parseCommand("criteria all").errorOrNil, "-- and a command are mandatory")
    }

    func testMoveNodeToMarkLandsAfterTheMarkedWindow() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0).marks = ["here"]
            TestWindow.new(id: 3, parent: $0)
        }
        _ = Window.get(byId: 1)!.focusWindow()
        try await HeadlessHarness.run("move-node-to-mark here")
        assertEquals(tree(), "h[v[2 1 3]]")
    }

    func testSwapWithMark() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer).marks = ["m"]
        try await HeadlessHarness.run("swap --with-mark m")
        assertEquals(tree(), "h[3 2 1]")
        XCTAssertNotNil(parseCommand("swap").errorOrNil)
        XCTAssertNotNil(parseCommand("swap left --with-mark m").errorOrNil)
    }

    func testI3PrefixStringSplit() {
        let s = splitI3CriteriaPrefix(#"[class="Foo Bar" floating] move-node-to-workspace 2"#)
        assertEquals(s?.terms, ["class=Foo Bar", "floating"])
        assertEquals(s?.rest, "move-node-to-workspace 2")
        XCTAssertNil(splitI3CriteriaPrefix("focus left"))
        XCTAssertNil(splitI3CriteriaPrefix("[class=x focus"))
    }

    func testI3PrefixRewrite() {
        assertEquals(rewriteI3CriteriaPrefix(["[class=Firefox", "title=x]", "focus"]), ["criteria", "class=Firefox", "title=x", "--", "focus"])
        assertEquals(rewriteI3CriteriaPrefix(["[floating]", "move-node-to-workspace", "2"]), ["criteria", "floating", "--", "move-node-to-workspace", "2"])
        assertEquals(rewriteI3CriteriaPrefix(["[]", "close"]), ["criteria", "all", "--", "close"])
        XCTAssertNil(rewriteI3CriteriaPrefix(["focus", "left"]))
    }
}
