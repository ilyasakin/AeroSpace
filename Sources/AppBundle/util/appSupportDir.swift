import Common
import Foundation

/// The single owner of "where this process may write persistent state".
///
/// Tests run under the SAME `aeroSpaceAppId` as the debug app, so any path derived straight from
/// `.applicationSupportDirectory` resolves to the developer's LIVE files — including the session
/// restore state that a running window manager reloads on launch. Nothing else separated the two:
/// session saves are debounced 0.4s onto the main queue, so the suite missed the write only because
/// the process exited first. A slower test, or one that pumps the main queue, would have silently
/// replaced a real session layout with a tree full of `TestWindow`s.
///
/// Redirecting under test (rather than refusing to write) keeps persistence exercisable while making
/// it impossible for a test to reach production state. Every persistent path must come from here.
@MainActor
enum AppSupportDir {
    /// Directory for this process's persistent state, created on demand by callers.
    static var url: URL {
        let base: URL = isUnitTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-tests", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(aeroSpaceAppId, isDirectory: true)
    }

    static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}
