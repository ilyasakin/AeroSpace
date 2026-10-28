@testable import AppBundle
import XCTest

/// Step 2 of the re-architecture: macOS is reached through ONE port — the `macos/` directory. Code
/// anywhere else that calls AX / SkyLight / CGWindowList / NSWorkspace, or reaches into the
/// production window/app classes, is a leak: it can't be simulated in tests, and it is where the
/// app's heuristics about macOS grew.
///
/// `stillLeaking` was the migration debt; it reached empty in step 2 and must stay empty.
final class MacOSPortBoundaryTest: XCTestCase {
    static let macOSApi = try! NSRegularExpression(pattern: #"AXUIElement|kAX[A-Z]|AXObserver|AXValue|\bSLS[A-Z]|SkyLight\.|CGWindowList|_SLPS|NSWorkspace\.shared|NSRunningApplication|CGEvent\.|CGEvent\(|CGDisplay|\.asMacWindow\(|as\?? MacWindow|macAppUnsafe|as\?? MacApp\b|MacWindow\.|MacApp\."#)

    /// Empty since step 2: nothing outside `macos/` may reach macOS. Do not add to it.
    static let stillLeaking: Set<String> = []

    func testMacOSIsReachedOnlyThroughThePort() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var leaking: Set<String> = []
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative.hasPrefix("macos/") { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
                .joined(separator: "\n")
            if Self.macOSApi.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                leaking.insert(relative)
            }
        }
        let newLeaks = leaking.subtracting(Self.stillLeaking)
        XCTAssertTrue(newLeaks.isEmpty, "macOS reached outside macos/ (go through the port): \(newLeaks.sorted())")
        let fixed = Self.stillLeaking.subtracting(leaking)
        XCTAssertTrue(fixed.isEmpty, "no longer leaking — remove from stillLeaking: \(fixed.sorted())")
    }
}
