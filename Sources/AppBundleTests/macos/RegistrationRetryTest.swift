@testable import AppBundle
import XCTest

@MainActor
final class RegistrationRetryTest: XCTestCase {
    override func setUp() async throws { RegistrationRetry.resetForTests() }

    func testBacksOffThenGivesUp() {
        XCTAssertEqual((0 ..< 6).map { _ in RegistrationRetry.failed(42) }, [0.5, 1, 2, 4, 8, nil])
    }

    func testSuccessResetsAndAppsAreIndependent() {
        _ = RegistrationRetry.failed(1)
        _ = RegistrationRetry.failed(1)
        XCTAssertEqual(RegistrationRetry.failed(2), 0.5)
        RegistrationRetry.succeeded(1)
        XCTAssertEqual(RegistrationRetry.failed(1), 0.5)
    }
}
