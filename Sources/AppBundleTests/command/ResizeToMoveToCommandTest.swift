@testable import AppBundle
import Common
import XCTest

@MainActor
final class ResizeToMoveToCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc(
            "resize-to 800 600",
            ResizeToCmdArgs(rawArgs: []).copy(\.width, .initialized(800)).copy(\.height, .initialized(600)),
        )
        testParseSingleCommandSucc(
            "move-to 100 200",
            MoveToCmdArgs(rawArgs: []).copy(\.x, .initialized(100)).copy(\.y, .initialized(200)),
        )
    }

    func testResizeToFloating() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 50, topLeftY: 50, width: 400, height: 300))
        }
        _ = window.focusWindow()
        await parseCommand("resize-to 800 600").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(try! await window.getAxSize(.nonCancellable), CGSize(width: 800, height: 600))
    }

    func testMoveToFloating() async {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.floatingWindowsContainer.apply {
            window = TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 50, topLeftY: 50, width: 400, height: 300))
        }
        _ = window.focusWindow()
        await parseCommand("move-to 120 80").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try! await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftCorner, CGPoint(x: 120, y: 80))
    }

    func testImporterSizeMoveWindowrule() {
        let hypr = """
            windowrulev2 = size 800 600, class:^(kitty)$
            windowrulev2 = move 10 20, class:^(kitty)$
            """
        let result = importHyprConfig(hypr)
        assertTrue(result.toml.contains("resize-to 800 600"))
        assertTrue(result.toml.contains("move-to 10 20"))
        assertTrue(result.toml.contains("layout floating"))
        let parsed = parseConfig(result.toml)
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
    }
}
