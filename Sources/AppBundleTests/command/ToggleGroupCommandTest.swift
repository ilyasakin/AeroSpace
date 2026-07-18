@testable import AppBundle
import Common
import XCTest

@MainActor
final class ToggleGroupCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        // Default product config: flatten is on — groups must still work
        config.enableNormalizationFlattenContainers = true
    }

    func testParse() {
        assertNil(parseCommand("toggle-group").errorOrNil)
        assertNil(parseCommand("togglegroup").errorOrNil)
    }

    func testWrapSurvivesNormalization() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        _ = w1.focusWindow()

        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // Run the same normalization the refresh loop uses
        workspace.normalizeContainers()

        let parent = w1.parent as? TilingContainer
        assertNotNil(parent)
        assertEquals(parent?.layout, .accordion)
        assertEquals(parent?.children.count, 1)
        // Group must still be nested under root (not flattened away)
        assertTrue(parent !== root)
        assertTrue(parent?.parent === root || parent?.parent is TilingContainer)
    }

    func testWrapAndUnwrap() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        _ = w1.focusWindow()

        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals((w1.parent as? TilingContainer)?.layout, .accordion)

        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertTrue(w1.parent is TilingContainer)
        assertEquals((w1.parent as? TilingContainer)?.layout, .tiles)
    }

    func testNextWindowAbsorbedIntoGroup() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        _ = w1.focusWindow()

        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        let group = w1.parent as! TilingContainer
        assertEquals(group.layout, .accordion)
        assertEquals(group.children.count, 1)

        // New tiling window with focus on the group member → absorbed into the group
        let w3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        try await w3.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        workspace.normalizeContainers()

        assertEquals((w1.parent as? TilingContainer)?.layout, .accordion)
        assertTrue(w3.parent === w1.parent)
        assertEquals((w1.parent as? TilingContainer)?.children.count, 2)
    }
}
