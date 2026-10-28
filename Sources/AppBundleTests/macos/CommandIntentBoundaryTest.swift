@testable import AppBundle
import XCTest

/// Step 2: commands state intent (`requestFrame`, tree changes); the render pass is what writes
/// frames. A command that writes a frame itself bypasses layout — its write races the next layout
/// pass, and its belief bookkeeping is one more copy of the frame logic.
final class CommandIntentBoundaryTest: XCTestCase {
    /// `enable off`: layout stops, so restoring parked windows can't be left to it
    static let allowedToWriteFrames: Set<String> = ["EnableCommand.swift"]

    func testCommandsNeverWriteFramesThemselves() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle/command/impl")
        let writes = try NSRegularExpression(pattern: #"\.setAxFrame\(|\bsetAxFrame\(|writeFrame\("#)
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" && !Self.allowedToWriteFrames.contains(file.lastPathComponent)
        {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
                .joined(separator: "\n")
            if writes.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "commands must requestFrame(...) and let the render pass write it")
    }
}
