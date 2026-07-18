@testable import AppBundle
import Common
import XCTest

@MainActor
final class DwindleTilingTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Workspace.clearTilingStructureGenerations()
    }

    private func insertTiled(_ window: Window, on workspace: Workspace) async throws {
        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
    }

    func testDwindle_binarySplitsByAspectRatio() async throws {
        config.tilingPolicy = .dwindle
        let workspace = Workspace.get(byName: name)

        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080) // wide -> h split

        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)

        // Re-fetch after path-copy materialize (live containers are rebuilt)
        var root = workspace.rootTilingContainer
        assertEquals(root.children.count, 1)
        var wrapper = root.children[0] as! TilingContainer
        assertEquals(wrapper.orientation, .h)
        assertEquals(wrapper.children.map { ($0 as! Window).windowId }, [1, 2])

        // B's tile is taller than wide -> next split is vertical, inside B's tile
        _ = b.focusWindow()
        b.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080)
        let c = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        try await insertTiled(c, on: workspace)

        root = workspace.rootTilingContainer
        wrapper = root.children[0] as! TilingContainer
        assertEquals(wrapper.children.count, 2)
        assertEquals((wrapper.children[0] as! Window).windowId, 1)
        let innerWrapper = wrapper.children[1] as! TilingContainer
        assertEquals(innerWrapper.orientation, .v)
        assertEquals(innerWrapper.children.map { ($0 as! Window).windowId }, [2, 3])
    }

    func testDwindle_splitsTheFocusedTileNotTheNewest() async throws {
        config.tilingPolicy = .dwindle
        let workspace = Workspace.get(byName: name)
        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)

        // Focus stays on A (windows can open in the background without stealing focus):
        // C must split A's tile, branching the tree instead of spiraling.
        // Note: B's bind() marked B as most-recent, so this also proves focus wins over MRU
        assertEquals(focus.windowOrNil?.windowId, 1)
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080) // tall -> v split
        let c = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        try await insertTiled(c, on: workspace)

        let wrapper = workspace.rootTilingContainer.children[0] as! TilingContainer
        let aWrapper = wrapper.children[0] as! TilingContainer
        assertEquals(aWrapper.orientation, .v)
        assertEquals(aWrapper.children.map { ($0 as! Window).windowId }, [1, 3])
        assertEquals((wrapper.children[1] as! Window).windowId, 2)
    }

    func testDwindle_splitRatioAssignsWeights() async throws {
        config.tilingPolicy = .dwindle
        config.dwindleSplitPercent = 62 // golden-ish
        let workspace = Workspace.get(byName: name)
        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)

        let wrapper = workspace.rootTilingContainer.children[0] as! TilingContainer
        assertTrue(abs(a.hWeight - 1.24) < 0.001)
        assertTrue(abs(b.hWeight - 0.76) < 0.001)
        assertEquals(wrapper.orientation, .h)
    }

    func testDwindle_closeCollapsesWrapper() async throws {
        config.tilingPolicy = .dwindle
        let workspace = Workspace.get(byName: name)
        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)

        a.closeAxWindow()
        // flatten-containers normalization is disabled in tests; dwindle must collapse anyway
        assertEquals(config.enableNormalizationFlattenContainers, false)
        workspace.normalizeContainers()

        assertEquals(workspace.rootTilingContainer.children.map { ($0 as! Window).windowId }, [2])
    }

    func testTilingPolicyCommand_overridesPerWorkspace() async {
        let workspace = Workspace.get(byName: name)
        assertTrue(workspace.focusWorkspace())
        assertEquals(workspace.effectiveTilingPolicy, .manual)

        await parseCommand("tiling-policy dwindle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.effectiveTilingPolicy, .dwindle)
        assertEquals(config.tilingPolicy, .manual) // config untouched

        await parseCommand("tiling-policy default").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.effectiveTilingPolicy, .manual)
    }

    func testManualPolicyUnchanged() async throws {
        let workspace = Workspace.get(byName: name)
        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)
        // Classic behavior: flat siblings, no wrapper
        assertEquals(workspace.rootTilingContainer.children.map { ($0 as! Window).windowId }, [1, 2])
    }

    /// Path-copy dwindle is published on the generation before materialize
    func testDwindlePlacePublishesPathCopyGeneration() async throws {
        config.tilingPolicy = .dwindle
        let workspace = Workspace.get(byName: name)
        let a = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = a.focusWindow()
        a.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let b = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await insertTiled(b, on: workspace)
        let gen = try XCTUnwrap(workspace.tilingStructureGeneration)
        // Root is a single split container with both windows
        XCTAssertEqual(gen.windowIds, [1, 2])
        guard case .container(_, _, _, let children) = gen else {
            return XCTFail("expected root container")
        }
        // After dwindle of sole root window: either root is the wrapper or root has one wrapper child
        let hasSplit = children.count == 2 || (
            children.count == 1 && {
                if case .container(_, _, _, let inner) = children[0] { return inner.count == 2 }
                return false
            }()
        )
        XCTAssertTrue(hasSplit)
    }
}
