@testable import AppBundle
import Common
import XCTest

/// `move <direction>` pinned to i3's own test suite (i3/testcases/t/124-move.t,
/// 274-move-branch-position.t). Each case builds the tree the i3 test builds, replays the same
/// focus history, and asserts i3's expected result.
@MainActor
final class I3MoveParityTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableNormalizationFlattenContainers = true
    }

    private var ws: Workspace { focus.workspace }
    private func tree() -> String { ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: "") }
    private func focusHistory(_ ids: UInt32...) { for id in ids { _ = Window.get(byId: id)!.focusWindow() } }

    func testUselessMovesOfTheOnlyWindow() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run(["move left", "move right", "move up", "move down"])
        assertEquals(tree(), "h[1]")
    }

    func testSwapWithSiblingAndStopAtEdge() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("move left")
        assertEquals(tree(), "h[2 1]")
        try await HeadlessHarness.run("move left") // edge, single output: nothing
        assertEquals(tree(), "h[2 1]")
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "h[1 2]")
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "h[1 2]")
    }

    /// 124-move.t: h[1 v[2] 3*] → move left enters v below its focused leaf; move up swaps; move
    /// left leaves the v branch beside it; move right re-enters the branch
    func testMoveIntoAndOutOfPerpendicularBranch() async throws {
        config.enableNormalizationFlattenContainers = false // i3 keeps single-child split cons
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
        }
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        focusHistory(2, 3)

        try await HeadlessHarness.run("move left")
        assertEquals(tree(), "h[1 v[2 3]]")
        try await HeadlessHarness.run("move up")
        assertEquals(tree(), "h[1 v[3 2]]")
        try await HeadlessHarness.run("move left")
        assertEquals(tree(), "h[1 3 v[2]]")
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "h[1 v[2 3]]")
    }

    /// 124-move.t second workspace: moving out of a v branch enters the neighbouring v branch
    /// after its focused leaf; the emptied branch closes → one node left
    func testMovingOutEntersNeighbouringBranch() async throws {
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 4, parent: $0)
        }
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        focusHistory(2, 3, 1, 4)
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "h[1 v[2 3 4]]") // i3 keeps v[1]; flatten normalization collapses it
        try await HeadlessHarness.run(["focus left", "move right"])
        // The root holds one v branch (flattened into the root itself)
        assertEquals(tree(), "v[2 3 4 1]")
    }

    /// Moving right into a tabbed (h accordion) branch → first tab (274-move-branch-position.t)
    func testMoveRightIntoTabsBecomesFirstTab() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer(parent: ws.rootTilingContainer, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
            for id: UInt32 in 2 ... 5 { TestWindow.new(id: id, parent: $0) }
        }
        focusHistory(5, 3, 1)
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "ha[1 2 3 4 5]")
    }

    /// Moving right into a stack (v accordion) → below its focused-inactive leaf
    func testMoveRightIntoStackGoesBelowFocusedLeaf() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer(parent: ws.rootTilingContainer, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).apply {
            for id: UInt32 in 2 ... 5 { TestWindow.new(id: id, parent: $0) }
        }
        focusHistory(5, 3, 1)
        try await HeadlessHarness.run("move right")
        assertEquals(tree(), "va[2 3 1 4 5]")
    }

    /// Moving down into a stack → top of the stack
    func testMoveDownIntoStackGoesOnTop() async throws {
        ws.rootTilingContainer.changeOrientation(.v)
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer(parent: ws.rootTilingContainer, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).apply {
            for id: UInt32 in 2 ... 5 { TestWindow.new(id: id, parent: $0) }
        }
        focusHistory(5, 3, 1)
        try await HeadlessHarness.run("move down")
        assertEquals(tree(), "va[1 2 3 4 5]")
    }

    /// i3 ws_force_orientation: no vertical ancestor → the root gains one, the window lands above
    func testMoveUpInHorizontalWorkspaceForcesOrientation() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("move up")
        assertEquals(tree(), "v[2 1]")
    }

    /// Same-orientation sibling container: enter at the near end (was: always index 0)
    func testMoveLeftIntoSameOrientationSiblingEntersAtNearEnd() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        TilingContainer.newHTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        TestWindow.new(id: 3, parent: ws.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("move left")
        // Flattened by normalization into the root; the order is what matters: 3 at the near end
        assertEquals(tree(), "h[1 2 3]")
    }
}

/// i3 tree normalization (tree.c tree_flatten) behind `i3-normalization = true`
@MainActor
final class I3NormalizationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.i3Normalization = true
        config.enableNormalizationFlattenContainers = true // overridden by i3-normalization
    }

    private var ws: Workspace { focus.workspace }
    private func tree() -> String { ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: "") }

    func testRedundantPairCollapsesIntoGrandparent() {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        ws.normalizeContainers()
        assertEquals(tree(), "h[1 2 3]")
    }

    func testSingleChildSplitHoldingAWindowIsKept() {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
        }
        ws.normalizeContainers()
        assertEquals(tree(), "h[1 v[2]]")
    }

    func testSplitWorksAndEmptyContainersClose() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run("split vertical")
        assertEquals(tree(), "h[v[1] 2]")
        try await HeadlessHarness.run("close")
        assertEquals(tree(), "h[2]") // the emptied v closed
    }
}
