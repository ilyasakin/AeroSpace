@testable import AppBundle
import Common
import XCTest

/// Mouse-resize weight diffs need a layout baseline (`lastApplied`) vs a live frame.
/// Invalidating lastApplied on every AX resized event made every drag tick a no-op.
final class ResizeWithMouseTest: XCTestCase {
    func testResizeDiffRequiresLastAppliedBaseline() {
        let live = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)
        let baseline = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        XCTAssertTrue(resizeWithMouseCanApplyDiffs(lastApplied: baseline, live: live))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(lastApplied: nil, live: live))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(lastApplied: baseline, live: nil))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(lastApplied: nil, live: nil))
    }

    func testInvalidateClearsBaselineThatResizeNeeds() {
        // Documents the bug class: invalidateAxFrameCaches drops lastApplied; resize then bails.
        let window = TestWindowHarness()
        window.lastApplied = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        XCTAssertTrue(resizeWithMouseCanApplyDiffs(lastApplied: window.lastApplied, live: window.lastApplied))
        window.lastApplied = nil // same effect as MacWindow.invalidateAxFrameCaches()
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(lastApplied: window.lastApplied, live: window.live))
    }
}

/// Minimal stand-in so the test does not need a full workspace tree.
private final class TestWindowHarness {
    var lastApplied: Rect?
    var live: Rect? = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)
}
