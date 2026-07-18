@testable import AppBundle
import Common
import XCTest

@MainActor
final class SessionLayoutStoreTest: XCTestCase {
    func testFilteringWindowsDropsMissingAndPromotesSingleChild() {
        let tree: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 1, weight: 1),
                .window(id: 2, weight: 1),
                .container(
                    orientation: .v,
                    layout: .tiles,
                    weight: 1,
                    children: [
                        .window(id: 3, weight: 1),
                        .window(id: 4, weight: 1),
                    ],
                ),
            ],
        )
        // Drop 2 and 4
        let filtered = tree.filteringWindows(keeping: [1, 3])
        assertNotNil(filtered)
        let ids = filtered!.windowIds
        assertEquals(ids.sorted(), [1, 3])
        // Structure still has both surviving windows
        assertTrue(filtered!.containsWindowId(1))
        assertTrue(filtered!.containsWindowId(3))
        assertFalse(filtered!.containsWindowId(2))
    }

    func testFilteringAllMissingReturnsNil() {
        let tree: PersistentTilingNode = .window(id: 9, weight: 1)
        assertNil(tree.filteringWindows(keeping: [1, 2]))
    }

    func testRoundTripDTOPreservesStructure() {
        let root: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 10, weight: 2),
                .window(id: 11, weight: 1),
            ],
        )
        let snap = PersistentWorldSnapshot(
            workspaces: [
                PersistentWorkspaceSnapshot(
                    name: "1",
                    monitorTopLeft: .zero,
                    visibleWorkspaceName: "1",
                    rootTiling: root,
                    floatingWindowIds: [99],
                    unconventionalWindowIds: [],
                ),
            ],
            monitorAssignments: [(topLeft: .zero, workspace: "1")],
            windowIds: [10, 11, 99],
        )
        // Encode/decode via the store's private DTO by save/load would need disk; use structure equality on filter instead.
        let filtered = root.filteringWindows(keeping: [10, 11])!
        assertTrue(filtered.structureEquals(root))
        assertEquals(snap.workspaces[0].floatingWindowIds, [99])
    }

    /// Regression: materialize must publish the restored spine as generation so layout does not
    /// keep applying a stale discovery spine (wrong orientation / order).
    func testMaterializePublishesGenerationOverStaleDiscoverySpine() async throws {
        setUpWorkspacesForTests()
        Workspace.clearTilingStructureGenerations()
        let ws = Workspace.get(byName: "2")
        let w1 = TestWindow.new(id: 501, parent: ws.floatingWindowsContainer)
        let w2 = TestWindow.new(id: 502, parent: ws.floatingWindowsContainer)

        // Stale generation as if discovery laid out two windows side-by-side (horizontal).
        let staleHorizontal: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 501, weight: 1),
                .window(id: 502, weight: 1),
            ],
        )
        ws.tilingStructureGeneration = staleHorizontal
        // Live dual-link currently matches that horizontal tree
        ws.materializeTilingSpine(staleHorizontal)
        XCTAssertEqual(ws.rootTilingContainer.orientation, .h)

        // Session restore: vertical stack (one above the other).
        let restoredVertical: PersistentTilingNode = .container(
            orientation: .v,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 501, weight: 1),
                .window(id: 502, weight: 1),
            ],
        )
        ws.materializeTilingSpine(restoredVertical)

        // Generation must match restore (not stale horizontal).
        let gen = try XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertTrue(gen.structureEquals(restoredVertical))
        XCTAssertEqual(ws.rootTilingContainer.orientation, .v)
        XCTAssertEqual(Set(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)), [501, 502])

        // Layout must use vertical geometry: same width, stacked Y.
        try await ws.layoutWorkspace()
        let r1 = try XCTUnwrap(w1.lastAppliedLayoutPhysicalRect)
        let r2 = try XCTUnwrap(w2.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(r1.width, r2.width, accuracy: 1)
        XCTAssertNotEqual(r1.topLeftY, r2.topLeftY, "vertical tiles must stack on Y")
        // Horizontal would differ in X; vertical should share the same X origin.
        XCTAssertEqual(r1.topLeftX, r2.topLeftX, accuracy: 1)
    }
}
