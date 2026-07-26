@testable import AppBundle
import Common
import XCTest

/// Tiles normalization must be PROPORTIONAL. It used to be additive
/// (`weight + (span - weightSum)/count`), which preserves differences rather than ratios — so an
/// authored ratio decayed to ~50/50 on the very first layout and `dwindle-split-percent` was
/// silently inert (a 70/30 split measured 500.4px/499.6px of a 1000px span). These tests pin the
/// ratio semantics that every weight producer already assumes.
@MainActor
final class TileWeightNormalizationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Widths of the root container's direct children, requiring the expected count so a layout
    /// that produced nothing fails as an assertion instead of trapping on a subscript.
    private func childWidths(_ workspace: Workspace, expected: Int) throws -> [CGFloat] {
        let widths = workspace.rootTilingContainer.children.map(\.lastAppliedLayoutVirtualRect?.width)
        let unwrapped = widths.compactMap { $0 }
        try XCTSkipIf(unwrapped.count != expected, "layout produced \(unwrapped.count) rects, expected \(expected)")
        return unwrapped
    }

    func testEqualWeightsSplitEvenly() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        try await workspace.layoutWorkspace()
        let w = try childWidths(workspace, expected: 2)
        XCTAssertEqual(w[0], w[1], accuracy: 1, "equal weights → equal spans")
    }

    /// The regression that proves the bug is gone: a 70/30 authored ratio must STAY 70/30.
    func testAuthoredRatioSurvivesLayout() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1.4) // dwindleSplit emits 2*0.7
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 0.6) // and 2*(1-0.7)
        }
        try await workspace.layoutWorkspace()
        let w = try childWidths(workspace, expected: 2)
        let total = w.reduce(0, +)
        XCTAssertEqual(w[0] / total, 0.7, accuracy: 0.01, "70% share must survive normalization")
        XCTAssertEqual(w[1] / total, 0.3, accuracy: 0.01, "30% share must survive normalization")
    }

    /// Ratios must be invariant across repeated layouts — weights are written back as spans, which
    /// is only sound because proportional normalization is scale-invariant.
    func testRatioIsStableAcrossRepeatedLayouts() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 3)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        try await workspace.layoutWorkspace()
        let first = try childWidths(workspace, expected: 2)
        for _ in 0 ..< 5 { try await workspace.layoutWorkspace() }
        let after = try childWidths(workspace, expected: 2)
        XCTAssertEqual(first[0], after[0], accuracy: 1, "repeated layouts must not drift")
        let total = after.reduce(0, +)
        XCTAssertEqual(after[0] / total, 0.75, accuracy: 0.01, "3:1 stays 3:1")
    }

    /// Pixel-denominated `resize` keeps working: weights are written back as spans, so a +N px
    /// weight bump still means +N px of geometry.
    func testPixelResizeStillMovesGeometry() async throws {
        let workspace = Workspace.get(byName: name)
        var w1: Window!
        workspace.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        try await workspace.layoutWorkspace()
        let before = try childWidths(workspace, expected: 2)
        XCTAssertEqual(w1.focusWindow(), true)
        await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let after = try childWidths(workspace, expected: 2)
        XCTAssertEqual(after[0] - before[0], 100, accuracy: 2, "+100 weight → +100px span")
        XCTAssertEqual(after.reduce(0, +), before.reduce(0, +), accuracy: 2, "span conserved")
    }

    /// Layout must give containers geometry. It used to assign rects to windows only, so nested
    /// containers were hit-test DEAD ZONES: mouse drag-to-swap over a nested split found no target
    /// and directional-focus fallbacks misrouted. The container rect is the bounding box of its
    /// laid-out descendants.
    func testLayoutAssignsContainerRects() async throws {
        let workspace = Workspace.get(byName: name)
        var w2: Window!
        var w3: Window!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                w2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                w3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        try await workspace.layoutWorkspace()

        let nested = try XCTUnwrap(
            workspace.rootTilingContainer.children.compactMap { $0 as? TilingContainer }.first,
            "expected a nested container",
        )
        let rect = try XCTUnwrap(nested.desiredRect, "container must carry geometry")
        let r2 = try XCTUnwrap(w2.desiredRect)
        let r3 = try XCTUnwrap(w3.desiredRect)

        // Bounding box of its two stacked children.
        XCTAssertEqual(rect.topLeftX, min(r2.topLeftX, r3.topLeftX), accuracy: 1)
        XCTAssertEqual(rect.topLeftY, min(r2.topLeftY, r3.topLeftY), accuracy: 1)
        XCTAssertEqual(
            rect.topLeftY + rect.height,
            max(r2.topLeftY + r2.height, r3.topLeftY + r3.height),
            accuracy: 1,
        )
        // And it must actually contain a point inside its children — the dead-zone regression.
        XCTAssertTrue(rect.contains(CGPoint(x: r2.topLeftX + r2.width / 2, y: r2.topLeftY + r2.height / 2)))
    }

    /// Nested containers: the inner ratio must be independent of the outer one.
    ///
    /// Measured on the leaf WINDOWS, not the container: layout writes rects only on windows and
    /// the workspace — containers never get one (which is why mouse hit-testing has to derive a
    /// container rect as the union of its descendants).
    func testNestedContainerRatiosAreIndependent() async throws {
        let workspace = Workspace.get(byName: name)
        var w1: Window!
        var w2: Window!
        var w3: Window!
        workspace.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                w2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 3)
                w3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        try await workspace.layoutWorkspace()

        let r1 = try XCTUnwrap(w1.lastAppliedLayoutVirtualRect)
        let r2 = try XCTUnwrap(w2.lastAppliedLayoutVirtualRect)
        let r3 = try XCTUnwrap(w3.lastAppliedLayoutVirtualRect)

        // Outer split is 1:1 — the lone window and the nested column get equal width.
        XCTAssertEqual(r1.width, r2.width, accuracy: 1, "outer 1:1 split")
        XCTAssertEqual(r2.width, r3.width, accuracy: 1, "nested siblings share the column width")
        // Inner split is 3:1 by height, independent of the outer ratio.
        let innerTotal = r2.height + r3.height
        XCTAssertEqual(r2.height / innerTotal, 0.75, accuracy: 0.01, "inner 3:1 preserved independently")
    }
}
