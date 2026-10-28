@testable import AppBundle
import Common
import XCTest

/// i3 container focus: `focus parent` / `focus child`, and commands acting on the focused container.
@MainActor
final class I3ContainerFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        WindowMemory.resetForTests()
    }

    private var ws: Workspace { focus.workspace }
    private func tree() -> String { ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: "") }

    /// h[v[1 2] 3], focus on 1
    private func buildVPairAndOne() {
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        _ = Window.get(byId: 1)!.focusWindow()
    }

    func testFocusParentAndChildWalkTheTree() async throws {
        buildVPairAndOne()
        try await HeadlessHarness.run("focus parent")
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 1)!.parent)
        try await HeadlessHarness.run("focus parent")
        XCTAssertTrue(focus.focusedNode === ws.rootTilingContainer)
        try await HeadlessHarness.run("focus parent") // bounded at the workspace root
        XCTAssertTrue(focus.focusedNode === ws.rootTilingContainer)
        try await HeadlessHarness.run(["focus child", "focus child", "focus child"])
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 1))
        assertEquals(focus.windowOrNil?.windowId, 1) // keyboard focus never moved
    }

    func testMoveMovesTheFocusedContainer() async throws {
        buildVPairAndOne()
        try await HeadlessHarness.run(["focus parent", "move right"])
        assertEquals(tree(), "h[3 v[1 2]]")
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 1)!.parent, "the container stays focused")
    }

    func testFocusingAnotherWindowResetsToWindowLevel() async throws {
        buildVPairAndOne()
        try await HeadlessHarness.run(["focus parent", "focus right"])
        assertEquals(focus.windowOrNil?.windowId, 3)
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 3))
    }

    func testCloseClosesEveryWindowOfTheFocusedContainer() async throws {
        buildVPairAndOne()
        try await HeadlessHarness.run(["focus parent", "close"])
        assertEquals(tree(), "h[3]")
    }

    func testLayoutChangesTheFocusedContainer() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        buildVPairAndOne()
        try await HeadlessHarness.run(["focus parent", "layout h_accordion"])
        assertEquals(tree(), "h[ha[1 2] 3]")
    }

    func testMoveContainerToWorkspace() async throws {
        buildVPairAndOne()
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 9, parent: other.rootTilingContainer)
        try await HeadlessHarness.run(["focus parent", "move-node-to-workspace other"])
        assertEquals(tree(), "h[3]")
        assertEquals(other.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[9 v[1 2]]")
    }

    func testDepartedWindowComesBackToItsSlot() async throws {
        // e.g. `close` answered by "Save changes?" (the window never actually closed), or a window
        // that briefly vanished from AX
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer).focusWindow()
        WindowMemory.noteLeaving(w2, from: ws.name)
        w2.closeAxWindow()
        assertEquals(tree(), "h[1 3]")
        let back = TestWindow.new(id: 2, parent: ws.floatingWindowsContainer)
        ws.placeRegisteredWindow(back)
        assertEquals(tree(), "h[1 2 3]") // not beside the focused 3
    }

    func testFocusNextFollowsTheParentsOrientation() async throws {
        buildVPairAndOne() // h[v[1* 2] 3]
        try await HeadlessHarness.run("focus next") // parent v → down
        assertEquals(focus.windowOrNil?.windowId, 2)
        // Bottom of v: "down" has no vertical ancestor beyond v → i3 wraps inside v
        try await HeadlessHarness.run("focus next")
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFocusNextSiblingFocusesTheSiblingNodeItself() async throws {
        buildVPairAndOne()
        _ = Window.get(byId: 3)!.focusWindow()
        try await HeadlessHarness.run("focus prev-sibling")
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 1)!.parent, "the v container is focused")
        try await HeadlessHarness.run("focus prev-sibling") // no wrap
        XCTAssertTrue(focus.focusedNode === Window.get(byId: 1)!.parent)
    }
}
