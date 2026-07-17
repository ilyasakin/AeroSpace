@testable import AppBundle
import Common
import XCTest

@MainActor
final class StickyCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseSingleCommandSucc("sticky", StickyCmdArgs(rawArgs: []))
        testParseCommandFail("sticky bogus", msg: "ERROR: Can't parse 'bogus'. Possible values: on|off", exitCode: 2)
        testParseCommandFail("sticky --fail-if-noop", msg: "--fail-if-noop requires 'on' or 'off' argument", exitCode: 2)
    }

    func testStickyWindow_followsWorkspaceSwitch() async {
        let workspaceA = Workspace.get(byName: name)
        var window: Window!
        workspaceA.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300))
        }
        _ = window.focusWindow()

        await parseCommand("sticky on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isSticky, true)
        assertEquals(window.nodeWorkspace?.name, workspaceA.name)

        _ = Workspace.get(byName: "sticky-target").focusWorkspace()
        followActiveWorkspaceForStickyWindows()

        assertEquals(window.nodeWorkspace?.name, "sticky-target")
        assertEquals(window.isFloating, true)
    }

    func testUnsticky_stopsFollowing() async {
        let workspaceA = Workspace.get(byName: name)
        var window: Window!
        workspaceA.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0)
        }
        _ = window.focusWindow()

        await parseCommand("sticky on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("sticky off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isSticky, false)

        _ = Workspace.get(byName: "sticky-target-2").focusWorkspace()
        followActiveWorkspaceForStickyWindows()

        assertEquals(window.nodeWorkspace?.name, workspaceA.name)
    }

    func testOn_forceFloatsTiledWindow() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.rootTilingContainer.apply {
            window = TestWindow.new(id: 1, parent: $0)
        }
        _ = window.focusWindow()

        await parseCommand("sticky on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isSticky, true)
        assertEquals(window.isFloating, true)
    }

    func testMoveNodeToWorkspace_turnsStickyOff() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0)
        }
        _ = window.focusWindow()

        await parseCommand("sticky on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("move-node-to-workspace sticky-move-target").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(window.isSticky, false)
        assertEquals(window.nodeWorkspace?.name, "sticky-move-target")
    }
}
