@testable import AppBundle
import Common
import XCTest

/// Path-copy-first structural commit (#1215 cutover): mutate spine, then materialize live handles.
@MainActor
final class TilingStructureCommitTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TreeHistory.clear()
        Workspace.clearTilingStructureGenerations()
    }

    func testCommitInsertUpdatesSpineThenLive() async throws {
        let ws = focus.workspace
        // Create window as floating handle first (commit materialize rebinds by id)
        let w1 = TestWindow.new(id: 101, parent: ws.floatingWindowsContainer)
        let w2 = TestWindow.new(id: 102, parent: ws.floatingWindowsContainer)

        // Seed generation with empty root capture (or one child)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 101, weight: 1))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 102, weight: 2))

        let gen = try XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertEqual(Set(gen.windowIds), [101, 102])

        // Live tree materialised from spine
        let liveIds = Set(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId))
        XCTAssertEqual(liveIds, [101, 102])
        XCTAssertTrue(w1.parent is TilingContainer)
        XCTAssertTrue(w2.parent is TilingContainer)

        // Layout uses generation (no liveChildren index pairing for geometry)
        try await ws.layoutWorkspace()
        let r1 = try await w1.getAxRect(.nonCancellable)
        let r2 = try await w2.getAxRect(.nonCancellable)
        XCTAssertNotNil(r1)
        XCTAssertNotNil(r2)
        XCTAssertGreaterThan(r1!.width, 0)
        XCTAssertGreaterThan(r2!.width, 0)
    }

    func testCommitRemoveUpdatesSpineThenLive() {
        let ws = focus.workspace
        TestWindow.new(id: 201, parent: ws.floatingWindowsContainer)
        TestWindow.new(id: 202, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 201))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 202))

        XCTAssertTrue(ws.commitTilingRemoveWindow(id: 201))
        let gen = try! XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertEqual(gen.windowIds, [202])
        XCTAssertEqual(
            ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId),
            [202],
        )
    }

    func testCommitIsPathCopyFirstNotLiveMutateThenCapture() {
        let ws = focus.workspace
        TestWindow.new(id: 301, parent: ws.floatingWindowsContainer)
        // Empty root capture
        let before = PersistentTilingNode.capture(ws.rootTilingContainer)
        ws.tilingStructureGeneration = before

        var transformSaw = before
        XCTAssertTrue(ws.commitTilingTransform { spine in
            transformSaw = spine
            return spine.inserting(
                child: .window(id: 301, weight: 1),
                at: INDEX_BIND_LAST,
                intoContainerAt: .root,
            )
        })
        // Transform received the published generation, not a post-hoc live re-capture of a dual-link mutate
        XCTAssertEqual(transformSaw, before)
        XCTAssertNotEqual(ws.tilingStructureGeneration, before)
        XCTAssertEqual(ws.tilingStructureGeneration?.windowIds, [301])
    }

    func testLayoutDoesNotRequireLiveChildIndexPairing() async throws {
        let ws = focus.workspace
        let w = TestWindow.new(id: 401, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 401, weight: 3))
        try await ws.layoutWorkspace()
        // Generation published after layout with weights
        let gen = try XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertTrue(gen.containsWindowId(401))
        let rect = try await w.getAxRect(.nonCancellable)
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect!.width * rect!.height, 0)
    }
}
