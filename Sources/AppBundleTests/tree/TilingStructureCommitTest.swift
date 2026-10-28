@testable import AppBundle
import Common
import XCTest

/// Structural commits: pure transforms of a fresh snapshot, applied back onto the one tree.
@MainActor
final class TilingStructureCommitTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    func testCommitInsertUpdatesSpineThenLive() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 101, parent: ws.floatingWindowsContainer)
        let w2 = TestWindow.new(id: 102, parent: ws.floatingWindowsContainer)

        XCTAssertTrue(ws.commitTilingInsertWindow(id: 101, weight: 1))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 102, weight: 2))

        let gen = ws.currentTilingSpine()
        XCTAssertEqual(Set(gen.windowIds), [101, 102])
        let liveIds = Set(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId))
        XCTAssertEqual(liveIds, [101, 102])
        XCTAssertTrue(w1.parent is TilingContainer)
        XCTAssertTrue(w2.parent is TilingContainer)

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
        let gen = ws.currentTilingSpine()
        XCTAssertEqual(gen.windowIds, [202])
        XCTAssertEqual(
            ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId),
            [202],
        )
    }

    func testCommitIsPathCopyFirstNotLiveMutateThenCapture() {
        let ws = focus.workspace
        TestWindow.new(id: 301, parent: ws.floatingWindowsContainer)
        let before = PersistentTilingNode.capture(ws.rootTilingContainer)

        var transformSaw = before
        XCTAssertTrue(ws.commitTilingTransform { spine in
            transformSaw = spine
            return spine.inserting(
                child: .window(id: 301, weight: 1),
                at: INDEX_BIND_LAST,
                intoContainerAt: .root,
            )
        })
        XCTAssertEqual(transformSaw, before)
        XCTAssertNotEqual(ws.currentTilingSpine(), before)
        XCTAssertEqual(ws.currentTilingSpine().windowIds, [301])
    }

    func testLayoutDoesNotRequireLiveChildIndexPairing() async throws {
        let ws = focus.workspace
        let w = TestWindow.new(id: 401, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 401, weight: 3))
        try await ws.layoutWorkspace()
        let gen = ws.currentTilingSpine()
        XCTAssertTrue(gen.containsWindowId(401))
        let rect = try await w.getAxRect(.nonCancellable)
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect!.width * rect!.height, 0)
    }

    /// Reorder, nested re-layout and weight change all show up in the next layout
    func testGenerationFreshnessMatrix_reorder_nestedStable_setWeight() async throws {
        let ws = focus.workspace

        // ── A: dual-link reorder (same id set) ─────────────────────────────
        let a = TestWindow.new(id: 501, parent: ws.floatingWindowsContainer)
        let b = TestWindow.new(id: 502, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 501, weight: 1))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 502, weight: 1))
        try await ws.layoutWorkspace()

        let root = ws.rootTilingContainer
        a.unbindFromParent()
        b.unbindFromParent()
        b.bind(to: root, adaptiveWeight: 1, index: 0)
        a.bind(to: root, adaptiveWeight: 1, index: 1)
        XCTAssertEqual(
            ws.rootTilingContainer.children.compactMap { ($0 as? Window)?.windowId },
            [502, 501],
        )

        try await ws.layoutWorkspace()
        XCTAssertEqual(ws.currentTilingSpine().windowIds, [502, 501])
        let rb = try await b.getAxRect(.nonCancellable)
        let ra = try await a.getAxRect(.nonCancellable)
        XCTAssertNotNil(rb)
        XCTAssertNotNil(ra)
        if ws.rootTilingContainer.orientation == .h {
            XCTAssertLessThan(rb!.topLeftX, ra!.topLeftX, "A: B left of A after swap+layout")
        }

        // ── B: nested tree, layout twice, no mutation — weights stable ─────
        for child in Array(ws.rootTilingContainer.children) {
            child.unbindFromParent()
            if let w = child as? Window {
                w.bindAsFloatingWindow(to: ws)
            }
        }
        // Ensure floating handles for nested commit
        let w1 = Window.get(byId: 501) ?? TestWindow.new(id: 501, parent: ws.floatingWindowsContainer)
        let w2 = Window.get(byId: 502) ?? TestWindow.new(id: 502, parent: ws.floatingWindowsContainer)
        let w3 = TestWindow.new(id: 503, parent: ws.floatingWindowsContainer)
        _ = w1; _ = w2; _ = w3
        for id in [501 as UInt32, 502, 503] {
            if Window.get(byId: id)?.parent is TilingContainer {
                Window.get(byId: id)?.unbindFromParent()
                Window.get(byId: id)?.bindAsFloatingWindow(to: ws)
            }
        }
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
                        .window(id: 501, weight: 1),
                        .window(id: 502, weight: 1),
                    ],
                ),
                .window(id: 503, weight: 1),
            ],
        )
        XCTAssertTrue(ws.commitTilingTransform { _ in nested })
        try await ws.layoutWorkspace()
        let genB1 = ws.currentTilingSpine()
        try await ws.layoutWorkspace()
        let genB2 = ws.currentTilingSpine()
        XCTAssertEqual(genB1, genB2, "B: a clean re-layout changes nothing")
        guard case .container(_, _, _, let ch1, _) = genB1,
              case .container(_, _, let nestedW1, _, _) = ch1[0],
              case .container(_, _, _, let ch2, _) = genB2,
              case .container(_, _, let nestedW2, _, _) = ch2[0]
        else { return XCTFail("B: expected nested container") }
        XCTAssertEqual(nestedW1, nestedW2)

        // ── C: setWeight (resize path) invalidates; next layout follows new weights ─
        for child in Array(ws.rootTilingContainer.children) {
            child.unbindFromParent()
        }
        let left = TestWindow.new(id: 701, parent: ws.floatingWindowsContainer)
        let right = TestWindow.new(id: 702, parent: ws.floatingWindowsContainer)
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 701, weight: 1))
        XCTAssertTrue(ws.commitTilingInsertWindow(id: 702, weight: 1))
        try await ws.layoutWorkspace()
        let beforeW = ws.currentTilingSpine()
        let rLeft0 = try await left.getAxRect(.nonCancellable)!
        let rRight0 = try await right.getAxRect(.nonCancellable)!

        // Real dual-link weight change (ResizeCommand / mouse path)
        let parent = try XCTUnwrap(left.parent as? TilingContainer)
        left.setWeight(parent.orientation, left.getWeight(parent.orientation) * 3)

        try await ws.layoutWorkspace()
        let afterW = ws.currentTilingSpine()
        XCTAssertNotEqual(beforeW, afterW)
        let rLeft1 = try await left.getAxRect(.nonCancellable)!
        let rRight1 = try await right.getAxRect(.nonCancellable)!
        // Left should be wider after heavier weight (horizontal root)
        if parent.orientation == .h {
            XCTAssertGreaterThan(rLeft1.width, rLeft0.width, "C: heavier weight → wider frame")
            XCTAssertLessThan(rRight1.width, rRight0.width, "C: sibling shrinks")
        }
    }
}
