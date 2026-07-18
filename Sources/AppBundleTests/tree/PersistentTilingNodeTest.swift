@testable import AppBundle
import Common
import XCTest

/// Immutable path-copying tiling tree (#1215 foundation).
@MainActor
final class PersistentTilingNodeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TreeHistory.clear()
    }

    private func sampleTree() -> PersistentTilingNode {
        .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 1, weight: 1),
                .container(
                    orientation: .v,
                    layout: .tiles,
                    weight: 1,
                    children: [
                        .window(id: 2, weight: 2),
                        .window(id: 3, weight: 3),
                    ],
                ),
            ],
        )
    }

    func testWindowIdsDepthFirst() {
        XCTAssertEqual(sampleTree().windowIds, [1, 2, 3])
    }

    func testPathOfWindow() {
        let tree = sampleTree()
        XCTAssertEqual(tree.path(ofWindowId: 1), PersistentPath(indices: [0]))
        XCTAssertEqual(tree.path(ofWindowId: 2), PersistentPath(indices: [1, 0]))
        XCTAssertEqual(tree.path(ofWindowId: 3), PersistentPath(indices: [1, 1]))
        XCTAssertNil(tree.path(ofWindowId: 99))
    }

    func testInsertPathCopySharesUnchangedSiblings() {
        let tree = sampleTree()
        let newWin = PersistentTilingNode.window(id: 4, weight: 1)
        // Insert into nested v-container (path [1])
        let updated = tree.inserting(child: newWin, at: INDEX_BIND_LAST, intoContainerAt: PersistentPath(indices: [1]))
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.windowIds, [1, 2, 3, 4])
        // Original tree unchanged (immutability)
        XCTAssertEqual(tree.windowIds, [1, 2, 3])
        // Sibling window 1 still the same value (path-copy only rebuilds ancestors)
        guard case .container(_, _, _, let oldChildren) = tree,
              case .container(_, _, _, let newChildren) = updated!
        else {
            return XCTFail("expected containers")
        }
        XCTAssertEqual(oldChildren[0], newChildren[0]) // shared left window leaf
    }

    func testRemove() {
        let tree = sampleTree()
        let path = PersistentPath(indices: [1, 0]) // window 2
        let result = tree.removing(at: path)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.removed, .window(id: 2, weight: 2))
        XCTAssertEqual(result!.root.windowIds, [1, 3])
        XCTAssertEqual(tree.windowIds, [1, 2, 3]) // original intact
    }

    func testSetWeight() {
        let tree = sampleTree()
        let path = PersistentPath(indices: [0])
        let updated = tree.settingWeight(9, at: path)
        XCTAssertEqual(updated?.node(at: path), .window(id: 1, weight: 9))
        XCTAssertEqual(tree.node(at: path), .window(id: 1, weight: 1))
    }

    func testCaptureAndRestoreRoundTrip() {
        let ws = Workspace.get(byName: "p")
        let root = ws.rootTilingContainer
        let w1 = TestWindow.new(id: 10, parent: root, adaptiveWeight: 1)
        let w2 = TestWindow.new(id: 11, parent: root, adaptiveWeight: 2)

        let captured = PersistentTilingNode.capture(root)
        XCTAssertEqual(Set(captured.windowIds), [10, 11])

        // Park windows as floating so Window.get(byId:) still finds them after the root is dropped
        // (unit-test lookup walks workspace leaves only)
        root.unbindFromParent()
        w1.bindAsFloatingWindow(to: ws)
        w2.bindAsFloatingWindow(to: ws)

        XCTAssertTrue(captured.restore(parent: ws, index: INDEX_BIND_LAST))
        let newRoot = ws.rootTilingContainer
        XCTAssertEqual(Set(newRoot.allLeafWindowsRecursive.map(\.windowId)), [10, 11])
    }

    func testTreeHistoryRecordsDistinctSnapshots() {
        let ws = Workspace.get(byName: "h")
        TestWindow.new(id: 20, parent: ws.rootTilingContainer)
        TreeHistory.recordLive()
        XCTAssertEqual(TreeHistory.count, 1)

        TreeHistory.recordLive() // identical — skipped
        XCTAssertEqual(TreeHistory.count, 1)

        TestWindow.new(id: 21, parent: ws.rootTilingContainer)
        TreeHistory.recordLive()
        XCTAssertEqual(TreeHistory.count, 2)
        XCTAssertEqual(TreeHistory.latest?.windowIds.contains(21), true)
    }

    func testFrozenContainerUsesPersistentSpine() {
        let ws = Workspace.get(byName: "f")
        TestWindow.new(id: 30, parent: ws.rootTilingContainer, adaptiveWeight: 1.5)
        let frozen = FrozenContainer(ws.rootTilingContainer)
        XCTAssertTrue(frozen.node.isContainer)
        XCTAssertEqual(frozen.node.windowIds, [30])
        // Nested window weight is preserved on the persistent spine
        if case .container(_, _, _, let children) = frozen.node,
           case .window(let id, let w) = children.first
        {
            XCTAssertEqual(id, 30)
            XCTAssertEqual(w, 1.5)
        } else {
            XCTFail("expected window child")
        }
    }
}
