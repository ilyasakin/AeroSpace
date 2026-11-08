@testable import AppBundle
import XCTest

@MainActor
final class PointerTapHealthTest: XCTestCase {
    func testASilentlyDisabledTapIsReenabledAndADeadOneRecreated() {
        XCTAssertEqual(PointerEvents.tapHealth(portIsValid: true, isEnabled: true), .ok)
        XCTAssertEqual(PointerEvents.tapHealth(portIsValid: true, isEnabled: false), .reenable)
        XCTAssertEqual(PointerEvents.tapHealth(portIsValid: false, isEnabled: false), .recreate)
        XCTAssertEqual(PointerEvents.tapHealth(portIsValid: false, isEnabled: true), .recreate)
    }

    func testTheTapIsNeverCreatedUnderTest() {
        Headless.resetForTests()
        PointerEvents.startObserving { _ in }
        XCTAssertFalse(PointerEvents.isObserving)
        XCTAssertEqual(Headless.blockedAttempts[.inputEventTap], 1)
    }
}
