@testable import AppBundle
import Common
import XCTest

/// A frame write is a request to another process. It can be clamped, ignored, fail, or - the case
/// nothing recorded - be cancelled by a newer write before it is ever sent, because
/// `MacApp.setAxFrame` cancels the outstanding per-window job first and `withWindowAsync` used to
/// swallow every outcome with `try?`.
///
/// This matters because belief is updated at SUBMISSION time, so a superseded write leaves belief
/// describing a frame the app was never asked for. The architecture names the measurement it wants
/// before building reconcile-with-acknowledgements: how many writes we generate, and how many are
/// discarded. These pin the accounting.
final class AxWriteStatsTest: XCTestCase {
    override func setUp() { AxWriteStats.resetForTests() }
    override func tearDown() { AxWriteStats.resetForTests() }

    func testCountersStartClean() {
        XCTAssertEqual(AxWriteStats.submitted, 0)
        XCTAssertEqual(AxWriteStats.superseded, 0)
        XCTAssertEqual(AxWriteStats.supersededShare, 0, "no submissions means no share, not a divide by zero")
    }

    func testSupersededShareIsRelativeToSubmissions() {
        for _ in 0 ..< 4 { AxWriteStats.noteSubmitted() }
        AxWriteStats.noteSuperseded()
        XCTAssertEqual(AxWriteStats.submitted, 4)
        XCTAssertEqual(AxWriteStats.superseded, 1)
        XCTAssertEqual(AxWriteStats.supersededShare, 0.25, accuracy: 0.0001)
    }

    /// Delivered and failed are distinct outcomes; before this they were both "nothing happened".
    func testDeliveredAndFailedAreDistinguished() {
        AxWriteStats.noteSubmitted()
        AxWriteStats.noteDelivered()
        AxWriteStats.noteSubmitted()
        AxWriteStats.noteFailed()
        XCTAssertEqual(AxWriteStats.delivered, 1)
        XCTAssertEqual(AxWriteStats.failed, 1)
        XCTAssertEqual(AxWriteStats.submitted, 2)
    }

    func testReportNamesEveryOutcome() {
        AxWriteStats.noteSubmitted()
        AxWriteStats.noteSuperseded()
        let r = AxWriteStats.report
        for field in ["submitted=", "delivered=", "superseded=", "failed="] {
            XCTAssertTrue(r.contains(field), "report should name \(field): \(r)")
        }
    }
}
