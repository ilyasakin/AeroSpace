@testable import AppBundle
import Common
import XCTest

final class FrameTraceFormatTest: XCTestCase {
    func testUnconstrainedCapFormatsInsteadOfTrapping() {
        // Crashed the app: a learned cap is `.infinity` in its unconstrained dimension
        XCTAssertEqual(fmt(CGFloat.infinity), "inf")
        XCTAssertEqual(fmt(CGFloat.nan), "nan")
        XCTAssertEqual(fmt(Rect(topLeftX: 1.6, topLeftY: 0, width: .infinity, height: 600)), "(2,0 infx600)")
    }
}
