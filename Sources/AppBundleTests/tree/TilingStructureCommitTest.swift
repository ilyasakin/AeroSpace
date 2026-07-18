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

    /// Nested tiling: second layout must keep first layout's adjusted weights (structureEquals
    /// ignores weights; container weights must also be synced to live so capture stays consistent).
    func testNestedTreeSecondLayoutKeepsAdjustedWeights() async throws {
        let ws = focus.workspace
        // Force a nested spine: H[ V[w1,w2], w3 ] via path-copy materialize
        let w1 = TestWindow.new(id: 601, parent: ws.floatingWindowsContainer)
        let w2 = TestWindow.new(id: 602, parent: ws.floatingWindowsContainer)
        let w3 = TestWindow.new(id: 603, parent: ws.floatingWindowsContainer)
        _ = w1; _ = w2; _ = w3
        let nested = PersistentTilingNode.container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .container(
                    orientation: .v,
                    layout: .tiles,
                    weight: 1,
                    children: [
                        .window(id: 601, weight: 1),
                        .window(id: 602, weight: 1),
                    ],
                ),
                .window(id: 603, weight: 1),
            ],
        )
        XCTAssertTrue(ws.commitTilingTransform { _ in nested })

        try await ws.layoutWorkspace()
        let gen1 = try XCTUnwrap(ws.tilingStructureGeneration)

        // Second layout must reuse gen weights (structureEquals), not recapture mixed weights
        try await ws.layoutWorkspace()
        let gen2 = try XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertTrue(gen1.structureEquals(gen2))
        // Nested container weights should remain layout-adjusted (not reset to 1 via stale capture)
        guard case .container(_, _, _, let children2) = gen2,
              case .container(_, _, let nestedWeight, _) = children2[0]
        else {
            return XCTFail("expected nested container")
        }
        guard case .container(_, _, _, let children1) = gen1,
              case .container(_, _, let nestedWeight1, _) = children1[0]
        else {
            return XCTFail("expected nested container in gen1")
        }
        XCTAssertEqual(nestedWeight, nestedWeight1)
        // Live nested container weight synced for capture consistency
        let liveNested = ws.rootTilingContainer.children.compactMap { $0 as? TilingContainer }.first
        XCTAssertNotNil(liveNested)
        if let liveNested, let parent = liveNested.parent as? TilingContainer {
            XCTAssertEqual(liveNested.getWeight(parent.orientation), nestedWeight1)
        }
    }

    /// Regression: dual-link reorder with the same window set must not keep a stale spine.
    /// After layout publishes generation, swap via dual-link bind and layout again — geometry
    /// must follow the live order (not undo the swap).
    func testDualLinkReorderThenLayoutFollowsLiveStructure() async throws {
        let ws = focus.workspace
        let a = TestWindow.new(id: 501, parent: ws.floatingWindowsContainer)
        let b = TestWindow.new(id: 502, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 501, weight: 1))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 502, weight: 1))
        try await ws.layoutWorkspace()
        // Generation published for A|B
        XCTAssertNotNil(ws.tilingStructureGeneration)

        // Dual-link swap → B|A (same window ids)
        let root = ws.rootTilingContainer
        a.unbindFromParent()
        b.unbindFromParent()
        b.bind(to: root, adaptiveWeight: 1, index: 0)
        a.bind(to: root, adaptiveWeight: 1, index: 1)
        // Dual-link mutation must invalidate (or full-structure compare must recapture)
        XCTAssertEqual(
            ws.rootTilingContainer.children.compactMap { ($0 as? Window)?.windowId },
            [502, 501],
        )

        try await ws.layoutWorkspace()
        let spine = try XCTUnwrap(ws.tilingStructureGeneration)
        // Spine order must match live B|A, not stale A|B
        XCTAssertEqual(spine.windowIds, [502, 501])

        let rb = try await b.getAxRect(.nonCancellable)
        let ra = try await a.getAxRect(.nonCancellable)
        XCTAssertNotNil(rb)
        XCTAssertNotNil(ra)
        // Horizontal root: first child is left of second
        if ws.rootTilingContainer.orientation == .h {
            XCTAssertLessThan(rb!.topLeftX, ra!.topLeftX, "B should be left of A after swap+layout")
        }
    }
}
