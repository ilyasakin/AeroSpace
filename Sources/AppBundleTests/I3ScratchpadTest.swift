@testable import AppBundle
import Common
import XCTest

/// i3 scratchpad semantics (src/scratchpad.c, testcases/t/185-scratchpad.t)
@MainActor
final class I3ScratchpadTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMoveHidesTheWindowAndShowTogglesIt() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w2.focusWindow()

        try await HeadlessHarness.run("scratchpad move")
        XCTAssertTrue(w2.nodeWorkspace?.isScratchpad == true)
        XCTAssertTrue(w2.isFloating)
        assertEquals(focus.windowOrNil?.windowId, 1)
        XCTAssertFalse(Workspace.userFacing.contains { $0.isScratchpad }, "the scratchpad is never listed")
        XCTAssertFalse(scratchpadWorkspace.isVisible)

        try await HeadlessHarness.run("scratchpad show")
        XCTAssertTrue(w2.nodeWorkspace === ws)
        XCTAssertTrue(w2.isFloating)
        assertEquals(focus.windowOrNil?.windowId, 2)

        // Focused scratchpad window + show = hide it again
        try await HeadlessHarness.run("scratchpad show")
        XCTAssertTrue(w2.nodeWorkspace?.isScratchpad == true)
    }

    func testShowFocusesAVisibleButUnfocusedScratchpadWindow() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w2.focusWindow()
        try await HeadlessHarness.run(["scratchpad move", "scratchpad show", "focus --window-id 1", "scratchpad show"])
        assertEquals(focus.windowOrNil?.windowId, 2)
        XCTAssertTrue(w2.nodeWorkspace === ws)
    }

    func testCriteriaTogglesAParticularScratchpadWindow() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        let w3 = TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run(["scratchpad move --window-id 2", "scratchpad move --window-id 3"])
        try await HeadlessHarness.run("[con_id=2] scratchpad show")
        XCTAssertTrue(w2.nodeWorkspace === ws)
        XCTAssertTrue(w3.nodeWorkspace?.isScratchpad == true)
    }

    func testTilingAScratchpadWindowTakesItOut() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w2.focusWindow()
        try await HeadlessHarness.run(["scratchpad move", "scratchpad show", "layout tiling"])
        XCTAssertFalse(w2.isScratchpadWindow)
        XCTAssertTrue(w2.parent is TilingContainer)
    }

    func testScratchpadCanNeverBeShownOnAMonitor() async throws {
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("scratchpad move")
        XCTAssertFalse(mainMonitor.setActiveWorkspace(scratchpadWorkspace))
        XCTAssertFalse(scratchpadWorkspace.isVisible)
    }
}

@MainActor
final class I3WorkspaceCommandsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWorkspaceNumberMatchesNamedWorkspace() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "3:mail").rootTilingContainer)
        try await HeadlessHarness.run("workspace --number 3")
        assertEquals(focus.workspace.name, "3:mail")
        try await HeadlessHarness.run("workspace --number 4")
        assertEquals(focus.workspace.name, "4")
    }

    func testAutoBackAndForthConfig() async throws {
        config.workspaceAutoBackAndForth = true
        try await HeadlessHarness.run("workspace a")
        try await HeadlessHarness.run("workspace b")
        try await HeadlessHarness.run("workspace b") // already on b → back to a
        assertEquals(focus.workspace.name, "a")
    }

    func testMoveNodeToWorkspaceBackAndForth() async throws {
        try await HeadlessHarness.run("workspace a")
        TestWindow.new(id: 1, parent: Workspace.get(byName: "b").rootTilingContainer)
        try await HeadlessHarness.run("workspace b")
        _ = Window.get(byId: 1)!.focusWindow()
        try await HeadlessHarness.run("move-node-to-workspace back-and-forth")
        XCTAssertTrue(Window.get(byId: 1)?.nodeWorkspace === Workspace.get(byName: "a"))
    }

    func testScratchpadIsNotAWorkspaceTarget() {
        // Underscore-prefixed names are reserved, so the scratchpad can't even be named
        XCTAssertNotNil(parseCommand("workspace __i3_scratch").errorOrNil)
        XCTAssertNotNil(parseCommand("move-node-to-workspace __i3_scratch").errorOrNil)
    }
}

@MainActor
final class I3FloatingCommandsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMoveFloatingWindowByPixels() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let f = TestWindow.new(id: 2, parent: ws.floatingWindowsContainer, rect: Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200))
        _ = f.focusWindow()
        try await HeadlessHarness.run("move left")
        assertEquals(f.laidOutRect?.topLeftX, 90)
        try await HeadlessHarness.run("move down 25 px")
        assertEquals(f.laidOutRect?.topLeftY, 125)
    }

    func testFocusFloatingTilingAndModeToggle() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.floatingWindowsContainer)
        try await HeadlessHarness.run("focus floating")
        assertEquals(focus.windowOrNil?.windowId, 2)
        try await HeadlessHarness.run("focus mode_toggle")
        assertEquals(focus.windowOrNil?.windowId, 1)
        try await HeadlessHarness.run("focus mode-toggle")
        assertEquals(focus.windowOrNil?.windowId, 2)
        try await HeadlessHarness.run("focus tiling")
        assertEquals(focus.windowOrNil?.windowId, 1)
    }
}

@MainActor
final class I3RenameWorkspaceTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRenameKeepsWindowsFocusMonitorAndBackAndForth() async throws {
        try await HeadlessHarness.run("workspace a")
        TestWindow.new(id: 1, parent: Workspace.get(byName: "b").rootTilingContainer)
        try await HeadlessHarness.run("workspace b")
        _ = Window.get(byId: 1)!.focusWindow()
        try await HeadlessHarness.run("rename-workspace mail")
        assertEquals(focus.workspace.name, "mail")
        XCTAssertTrue(focus.workspace.isVisible)
        assertEquals(focus.windowOrNil?.windowId, 1)
        XCTAssertFalse(Workspace.userFacing.contains { $0.name == "b" })
        try await HeadlessHarness.run("workspace-back-and-forth")
        assertEquals(focus.workspace.name, "a")
        try await HeadlessHarness.run("workspace-back-and-forth")
        assertEquals(focus.workspace.name, "mail")
    }

    func testRenameToAnExistingNameFails() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "taken").rootTilingContainer)
        let r = try await HeadlessHarness.run("rename-workspace taken")
        XCTAssertNotEqual(r.exitCode.rawValue, 0)
    }

    func testI3RenameImports() {
        assertEquals(i3MapCommandToAerospace("rename workspace to web"), "rename-workspace web")
        assertEquals(i3MapCommandToAerospace("rename workspace 1 to web"), "rename-workspace --workspace 1 web")
    }
}
