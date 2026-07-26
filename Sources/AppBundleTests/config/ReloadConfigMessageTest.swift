@testable import AppBundle
import Common
import XCTest

/// A recoverable config error (anything short of a TOML syntax error) applies the rest of the config
/// and drops only the offending entries. Both outcomes used to render as "Failed to parse", so a
/// typo in one binding produced a failure dialog while some of the user's keys had quietly stopped
/// existing. These assert the two outcomes cannot read the same.
final class ReloadConfigMessageTest: XCTestCase {
    private let url = URL(filePath: "/tmp/aerospace-test.toml")

    func testAppliedWithErrorsSaysSoAndNamesDroppedBindings() {
        let msg = failedToParseMsg(
            configUrl: url,
            errorsCount: 2,
            warningsCount: 0,
            lines: ["[ERROR] mode.main.binding.alt-hh: Can't parse the key in 'alt-hh' binding"],
            applied: true,
            droppedBindings: ["alt-hh", "aalt-j"],
        )
        XCTAssertTrue(msg.contains("Applied"), "must not claim outright failure when it applied: \(msg)")
        XCTAssertFalse(msg.contains("Failed to parse"))
        XCTAssertTrue(msg.contains("NO LONGER WORK"))
        XCTAssertTrue(msg.contains("alt-hh"))
        XCTAssertTrue(msg.contains("aalt-j"))
        // Bindings are listed in a stable order so the dialog doesn't shuffle between reloads
        let hh = try? XCTUnwrap(msg.range(of: "aalt-j"))
        let jj = try? XCTUnwrap(msg.range(of: "alt-hh"))
        if let hh, let jj { XCTAssertTrue(hh.lowerBound < jj.lowerBound, "sorted order expected") }
        // The underlying diagnostics are still shown
        XCTAssertTrue(msg.contains("Can't parse the key"))
    }

    func testRejectedSaysNothingWasApplied() {
        let msg = failedToParseMsg(
            configUrl: url,
            errorsCount: 1,
            warningsCount: 0,
            lines: ["[ERROR] (Line 1) Syntax error: invalid or missing key."],
            applied: false,
            droppedBindings: [],
        )
        XCTAssertTrue(msg.contains("Failed to parse"))
        XCTAssertTrue(
            msg.contains("still active"),
            "a rejected config must say the previous one is still in effect: \(msg)",
        )
        XCTAssertFalse(msg.contains("NO LONGER WORK"))
    }

    func testAppliedWithErrorsButNoDroppedBindingsOmitsTheBindingSection() {
        let msg = failedToParseMsg(
            configUrl: url,
            errorsCount: 1,
            warningsCount: 0,
            lines: ["[ERROR] window-detection-rules[0].treat-as: 'bogus' is invalid"],
            applied: true,
            droppedBindings: [],
        )
        XCTAssertTrue(msg.contains("Applied"))
        XCTAssertFalse(msg.contains("NO LONGER WORK"), "no bindings dropped -> no scary key list")
    }
}
