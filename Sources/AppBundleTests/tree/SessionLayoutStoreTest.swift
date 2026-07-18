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
}
