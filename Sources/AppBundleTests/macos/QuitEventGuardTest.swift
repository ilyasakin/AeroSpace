@testable import AppBundle
import XCTest

final class QuitEventGuardTest: XCTestCase {
    /// linkd quits background apps it believes it launched to read their App Intents
    func testTheAppIntentsDaemonCannotQuitTheWindowManager() {
        XCTAssertFalse(shouldHonorQuitAppleEvent(senderPath: "/usr/libexec/linkd", hasQuitReason: false))
    }

    func testLogoutRestartAndShutdownAlwaysQuit() {
        XCTAssertTrue(shouldHonorQuitAppleEvent(senderPath: "/usr/libexec/linkd", hasQuitReason: true))
        XCTAssertTrue(shouldHonorQuitAppleEvent(senderPath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", hasQuitReason: true))
    }

    func testAnyOtherSenderQuits() {
        XCTAssertTrue(shouldHonorQuitAppleEvent(senderPath: "/usr/bin/osascript", hasQuitReason: false))
        XCTAssertTrue(shouldHonorQuitAppleEvent(senderPath: "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", hasQuitReason: false))
        XCTAssertTrue(shouldHonorQuitAppleEvent(senderPath: nil, hasQuitReason: false), "unknown sender: don't block a quit")
    }
}
