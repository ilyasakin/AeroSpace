@testable import AppBundle
import Common
import XCTest

@MainActor
final class CenterWindowCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseSingleCommandSucc("center-window", CenterWindowCmdArgs(rawArgs: []))
        testParseCommandFail("center-window bogus", msg: "ERROR: Unknown argument 'bogus'", exitCode: 2)
    }

    func testCenterFloatingWindow_keepsSize() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300))
        }
        _ = window.focusWindow()

        await parseCommand("center-window").cmdOrDie.run(.defaultEnv, .emptyStdin)

        // Test monitor is 1920x1080 at (0, 0), zero gaps by default
        let rect = try! await window.getAxRect(.nonCancellable)!
        assertEquals(rect.topLeftX, (1920 - 400) / 2)
        assertEquals(rect.topLeftY, (1080 - 300) / 2)
        assertEquals(rect.width, 400)
        assertEquals(rect.height, 300)
        assertEquals(window.isFloating, true)
    }

    func testCenterTiledWindow_floatsFirst() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.rootTilingContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 10, topLeftY: 10, width: 600, height: 500))
        }
        _ = window.focusWindow()
        assertEquals(window.isFloating, false)

        await parseCommand("center-window").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(window.isFloating, true)
        let rect = try! await window.getAxRect(.nonCancellable)!
        assertEquals(rect.topLeftX, (1920 - 600) / 2)
        assertEquals(rect.topLeftY, (1080 - 500) / 2)
    }
}
