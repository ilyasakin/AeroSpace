@testable import AppBundle
import Common
import XCTest

final class FocusRecordTest: XCTestCase {
    func testTheUsersFocusChangeIsFollowed() {
        var record = FocusRecord()
        XCTAssertEqual(record.macosReported(1, now: 0), .changedByUser(1))
        XCTAssertEqual(record.macosReported(1, now: 1), .unchanged)
        XCTAssertEqual(record.macosReported(2, now: 2), .changedByUser(2))
    }

    func testOurRequestIsConfirmedNotMistakenForTheUser() {
        var record = FocusRecord()
        _ = record.macosReported(1, now: 0)
        record.noteModelAfterReport(1)
        XCTAssertTrue(record.needsRequest(for: 2, now: 0))
        record.noteRequested(2, now: 0)
        XCTAssertFalse(record.needsRequest(for: 2, now: 0.1), "asked already")
        // macOS hasn't switched yet: still the old focus, not a user change
        XCTAssertEqual(record.macosReported(1, now: 0.1), .unchanged)
        XCTAssertEqual(record.macosReported(2, now: 0.2), .confirmsRequest)
        XCTAssertFalse(record.needsRequest(for: 2, now: 0.3))
    }

    func testARefusedRequestHandsTheLeadBackToMacos() {
        var record = FocusRecord()
        _ = record.macosReported(1, now: 0)
        record.noteModelAfterReport(1)
        record.noteRequested(2, now: 0)
        XCTAssertEqual(record.macosReported(1, now: 0.5), .unchanged, "not landed yet")
        XCTAssertEqual(record.macosReported(1, now: 2), .changedByUser(1), "refused: the model follows macOS")
    }

    /// macOS reports no focused window (desktop click, a just-launched app's window not registered
    /// yet, a Space switch): the model can't follow, and must not push its old focus back
    func testNothingIsPushedWhenTheModelDidNotMove() {
        var record = FocusRecord()
        _ = record.macosReported(1, now: 0)
        record.noteModelAfterReport(1)
        XCTAssertEqual(record.macosReported(nil, now: 1), .changedByUser(nil))
        record.noteModelAfterReport(1) // nothing to follow: the model still says 1
        XCTAssertFalse(record.needsRequest(for: 1, now: 1), "macOS leads: that was the user")
        XCTAssertTrue(record.needsRequest(for: 2, now: 1), "AeroSpace moved focus (a command): ask")
    }

    func testTheUserOverridesAPendingRequest() {
        var record = FocusRecord()
        _ = record.macosReported(1, now: 0)
        record.noteRequested(2, now: 0)
        XCTAssertEqual(record.macosReported(3, now: 0.1), .changedByUser(3))
        XCTAssertNil(record.requested)
    }

    func testNothingToAskWhenMacosAlreadyAgrees() {
        var record = FocusRecord()
        _ = record.macosReported(4, now: 0)
        XCTAssertFalse(record.needsRequest(for: 4, now: 0))
        XCTAssertFalse(record.needsRequest(for: nil, now: 0))
    }
}
