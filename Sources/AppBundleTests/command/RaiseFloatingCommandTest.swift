@testable import AppBundle
import Common
import XCTest

@MainActor
final class RaiseFloatingCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseSingleCommandSucc("raise-floating", RaiseFloatingCmdArgs(rawArgs: []))
        testParseCommandFail("raise-floating bogus", msg: "ERROR: Unknown argument 'bogus'", exitCode: 2)
    }

    func testRaiseFloatingWithNoFloatsReportsAndSucceeds() async {
        let workspace = focus.workspace
        workspace.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
        }
        let result = await parseCommand("raise-floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testRaiseFloatingWithFloatsSucceeds() async {
        let workspace = focus.workspace
        var tile: Window!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        _ = tile.focusWindow()

        let result = await parseCommand("raise-floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        // Tree focus stays on the tile (recovery does not steal AeroSpace focus to a float).
        assertEquals(focus.windowOrNil?.windowId, tile.windowId)
    }
}
