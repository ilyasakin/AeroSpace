@testable import AppBundle
import Common
import XCTest

@MainActor
final class AlwaysOnTopCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseSingleCommandSucc("always-on-top", AlwaysOnTopCmdArgs(rawArgs: []))
        testParseCommandFail("always-on-top bogus", msg: "ERROR: Can't parse 'bogus'. Possible values: on|off", exitCode: 2)
        testParseCommandFail("always-on-top --fail-if-noop", msg: "--fail-if-noop requires 'on' or 'off' argument", exitCode: 2)
    }

    func testToggle_flipsFlag() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300))
        }
        _ = window.focusWindow()
        assertEquals(window.isAlwaysOnTop, false)

        await parseCommand("always-on-top").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isAlwaysOnTop, true)

        await parseCommand("always-on-top").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isAlwaysOnTop, false)
    }

    func testOn_forceFloatsTiledWindow() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.rootTilingContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300))
        }
        _ = window.focusWindow()

        await parseCommand("always-on-top on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isAlwaysOnTop, true)
        assertEquals(window.isFloating, true)
    }

    func testNoop_respectsFailIfNoop() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0)
        }
        _ = window.focusWindow()

        let result = await parseCommand("always-on-top off --fail-if-noop").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }
}
