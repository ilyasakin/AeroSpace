@testable import AppBundle
import Common
import XCTest

@MainActor
final class ToggleSpecialWorkspaceCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        SpecialWorkspaceToggleState.resetAll()
    }

    func testParse() {
        testParseSingleCommandSucc(
            "toggle-special-workspace scratch",
            ToggleSpecialWorkspaceCmdArgs(rawArgs: []).copy(\.target, .initialized(.parse("scratch").getOrDie())),
        )
        assertEquals(parseCommand("togglespecialworkspace magic").cmdOrNil != nil, true)
    }

    func testToggleBookkeepingPerMonitor() {
        let special = "scratch"
        let monA = "Built-in Retina Display"
        let monB = "DELL U2720Q"
        assertNil(SpecialWorkspaceToggleState.remembered(for: special, onMonitor: monA))
        SpecialWorkspaceToggleState.remember("1", for: special, onMonitor: monA)
        SpecialWorkspaceToggleState.remember("2", for: special, onMonitor: monB)
        // Per-monitor keys must not clobber each other
        assertEquals(SpecialWorkspaceToggleState.remembered(for: special, onMonitor: monA), "1")
        assertEquals(SpecialWorkspaceToggleState.remembered(for: special, onMonitor: monB), "2")
        SpecialWorkspaceToggleState.clear(for: special, onMonitor: monA)
        assertNil(SpecialWorkspaceToggleState.remembered(for: special, onMonitor: monA))
        assertEquals(SpecialWorkspaceToggleState.remembered(for: special, onMonitor: monB), "2")
    }

    func testToggleCommandSwapsAndReturns() async {
        let monName = focus.workspace.workspaceMonitor.name
        let wsMain = Workspace.get(byName: name)
        let wsScratch = Workspace.get(byName: "scratch")
        assertTrue(wsMain.focusWorkspace())
        assertEquals(focus.workspace.name, name)

        await parseCommand("toggle-special-workspace scratch").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "scratch")
        assertEquals(SpecialWorkspaceToggleState.remembered(for: "scratch", onMonitor: monName), name)

        await parseCommand("toggle-special-workspace scratch").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, name)
        assertNil(SpecialWorkspaceToggleState.remembered(for: "scratch", onMonitor: monName))
        _ = wsScratch
    }
}
