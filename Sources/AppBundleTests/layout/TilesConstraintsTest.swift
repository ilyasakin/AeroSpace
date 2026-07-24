@testable import AppBundle
import CoreGraphics
import XCTest

final class TilesConstraintsTest: XCTestCase {
    private func assertSpans(_ got: [CGFloat], _ want: [CGFloat], accuracy: CGFloat = 0.01) {
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: accuracy) }
    }

    func testNoCapsIsProportional() {
        let spans = waterfillTileSpans(weights: [1, 1, 2], caps: [nil, nil, nil], span: 400)
        assertSpans(spans, [100, 100, 200])
    }

    func testSingleCapRedistributesToSiblings() {
        // Middle window capped at 200; two equal siblings absorb the freed space.
        let spans = waterfillTileSpans(weights: [1, 1, 1], caps: [nil, 200, nil], span: 900)
        assertSpans(spans, [350, 200, 350])
    }

    func testCapAboveShareIsInert() {
        // Cap (500) is larger than the proportional share (300) → no effect.
        let spans = waterfillTileSpans(weights: [1, 1, 1], caps: [nil, 500, nil], span: 900)
        assertSpans(spans, [300, 300, 300])
    }

    func testCascadingCapsIterate() {
        // Two caps; freeing the first pushes a sibling past its own cap → second round.
        // span 1000, weights equal. First pass share 333: A capped 100, D capped 250.
        // Remaining 650 to B,C (weight 1 each) → 325 each.
        let spans = waterfillTileSpans(weights: [1, 1, 1, 1], caps: [100, nil, nil, 250], span: 1000)
        assertSpans(spans, [100, 325, 325, 250])
    }

    func testAllCappedLeavesTrailingGap() {
        // Everything capped below its share; total caps 600 < span 900 → 300 unavoidable gap.
        let spans = waterfillTileSpans(weights: [1, 1, 1], caps: [200, 200, 200], span: 900)
        assertSpans(spans, [200, 200, 200])
        XCTAssertLessThan(spans.reduce(0, +), 900)
    }

    func testSingleChildFillsSpan() {
        assertSpans(waterfillTileSpans(weights: [1], caps: [nil], span: 500), [500])
    }

    func testSingleCappedChildLeavesGap() {
        assertSpans(waterfillTileSpans(weights: [1], caps: [300], span: 500), [300])
    }

    func testWeightedRedistribution() {
        // A capped at 100; B and C share the rest 2:1.
        let spans = waterfillTileSpans(weights: [1, 2, 1], caps: [100, nil, nil], span: 700)
        assertSpans(spans, [100, 400, 200])
    }

    func testCapsActiveHelper() {
        XCTAssertFalse(tileCapsAreActive([nil, nil]))
        XCTAssertTrue(tileCapsAreActive([nil, 200]))
    }
}
