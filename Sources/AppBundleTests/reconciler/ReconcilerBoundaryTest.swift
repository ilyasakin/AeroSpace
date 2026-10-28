@testable import AppBundle
import XCTest

/// Step 3: what AeroSpace knows about a window's frame and about macOS's focus lives in the frame
/// and focus records, and every decision about it is a function of observed inputs and timestamps.
final class ReconcilerBoundaryTest: XCTestCase {
    private static let appBundle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppBundle")

    private func code(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .joined(separator: "\n")
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The guesses the records replaced — each once a separate copy of "where is it / who has focus"
    func testReplacedGuessesStayGone() throws {
        let gone = ["believedRect", "preWriteRect", "lastFrameWriteAt", "reconcileAttempts", "beliefWriteGeneration",
                    "framesWrittenThisSession", "classifyFrameNotification", "lastKnownNativeFocusedWindowId",
                    "maxSizeCandidate", "scheduleBeliefVerification"]
        for file in swiftFiles(under: Self.appBundle) {
            let source = try code(file)
            for name in gone where source.contains(name) {
                XCTFail("\(file.lastPathComponent) brings back `\(name)` — frame knowledge lives in FrameRecord, focus in FocusRecord")
            }
        }
    }

    /// Verdicts come from inputs, never from waiting to see what happens
    func testNoTimersInTheFrameAndFocusLogic() throws {
        let files = swiftFiles(under: Self.appBundle.appendingPathComponent("reconciler"))
            + [Self.appBundle.appendingPathComponent("tree/WindowFrame.swift")]
        for file in files {
            let source = try code(file)
            for timer in ["Task.sleep", "asyncAfter", "Timer.", "DispatchSemaphore"] where source.contains(timer) {
                XCTFail("\(file.lastPathComponent) uses \(timer)")
            }
        }
    }
}
