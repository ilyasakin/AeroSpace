@testable import AppBundle
import Common
import XCTest

/// The i3-compatible IPC `RUN_COMMAND` path used to call `Command.run` directly, skipping both
/// gates the native socket server applies: the server-enabled check and the surrounding refresh
/// session. Any i3 client (i3-msg, polybar, an editor plugin) could therefore keep driving the
/// window manager after the user had explicitly run `aerospace enable off`.
@MainActor
final class I3IpcServerGateTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        ServerState.isEnabled = true
    }

    func testRunCommandIsRefusedWhileServerDisabled() async throws {
        ServerState.isEnabled = false

        let data = await i3RunCommandPayload("focus left")
        let results = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "RUN_COMMAND replies with an array of per-command results",
        )
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first["success"] as? Bool, false, "a disabled server must refuse the command")
        let error = try XCTUnwrap(first["error"] as? String)
        XCTAssertTrue(
            error.contains("disabled"),
            "the refusal should say why, matching the native socket's wording. Got: \(error)",
        )
    }

    /// The refusal must be specific to being disabled — an unsupported verb is still reported as
    /// unsupported, so the gate cannot be mistaken for blanket rejection.
    func testUnsupportedCommandStillReportsUnsupportedWhileEnabled() async throws {
        ServerState.isEnabled = true

        let data = await i3RunCommandPayload("border pixel 3")
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first["success"] as? Bool, false)
        let error = try XCTUnwrap(first["error"] as? String)
        XCTAssertTrue(error.contains("unsupported"), "expected an unsupported-verb error, got: \(error)")
    }

    func testEmptyPayloadReportsFailure() async throws {
        let data = await i3RunCommandPayload("   ")
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(results.first?["success"] as? Bool, false)
    }
}
