@testable import AppBundle
import XCTest

/// Border geometry has one input — the window's live WindowServer frame. Every border/window
/// mismatch so far came from a border painting layout intent or belief instead. This keeps them out
/// of the border code (comments excepted), so a new "just use the target here" can't creep back in.
final class BorderGeometrySourceTest: XCTestCase {
    private static let borderSources = ["ui/WindowBorders.swift", "macos/BorderWindowServer.swift"]
    private static let forbidden = ["desiredRect", "knownFrame", "bestKnown", "lastAppliedLayoutVirtualRect", "windowServerMayLag"]

    func testBorderCodeNeverReadsIntentOrBelief() throws {
        let appBundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle")
        for file in Self.borderSources {
            let source = try String(contentsOf: appBundle.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                for name in Self.forbidden where code.contains(name) {
                    XCTFail("\(file):\(index + 1) reads `\(name)` — border geometry must come from the live WindowServer frame")
                }
            }
        }
    }
}
