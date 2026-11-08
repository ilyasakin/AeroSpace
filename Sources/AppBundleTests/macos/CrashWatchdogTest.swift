@testable import AppBundle
import XCTest

final class CrashWatchdogTest: XCTestCase {
    private let left = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let right = CGRect(x: 2560, y: 0, width: 1920, height: 1080)

    func testAWindowParkedInTheCornerGoesToTheMiddleOfItsDisplay() throws {
        // hideInCorner leaves a pixel-wide sliver at the bottom-right corner
        let parked = CGRect(x: 2559, y: 1439, width: 1200, height: 800)
        let origin = try XCTUnwrap(parkedWindowRestoreOrigin(parked, displays: [left]))
        XCTAssertEqual(origin, CGPoint(x: 680, y: 320))
    }

    func testAVisibleWindowIsLeftAlone() {
        XCTAssertNil(parkedWindowRestoreOrigin(CGRect(x: 100, y: 100, width: 800, height: 600), displays: [left]))
        // Mostly on screen, partly past the edge: the user put it there
        XCTAssertNil(parkedWindowRestoreOrigin(CGRect(x: 2000, y: 100, width: 800, height: 600), displays: [left]))
    }

    func testTheNearestDisplayIsUsed() throws {
        let parkedOnRight = CGRect(x: 4479, y: 1079, width: 1000, height: 500)
        let origin = try XCTUnwrap(parkedWindowRestoreOrigin(parkedOnRight, displays: [left, right]))
        XCTAssertEqual(origin, CGPoint(x: 2560 + 460, y: 290))
    }

    func testAWindowLargerThanTheDisplayStartsAtItsCorner() throws {
        let origin = try XCTUnwrap(parkedWindowRestoreOrigin(CGRect(x: 3000, y: 3000, width: 3000, height: 2000), displays: [left]))
        XCTAssertEqual(origin, .zero)
    }

    @MainActor
    func testTheWatchdogIsNeverSpawnedUnderTest() {
        Headless.resetForTests()
        CrashWatchdog.start()
        XCTAssertEqual(Headless.blockedAttempts[.spawnProcess], 1)
    }

    func testOrdinaryLaunchArgumentsDoNotEnterWatchdogMode() {
        CrashWatchdog.runIfRequested(["AeroSpaceApp"]) // returns: would exit otherwise
        CrashWatchdog.runIfRequested(["AeroSpaceApp", "--aerospace-crash-watchdog"]) // no pid
    }
}
