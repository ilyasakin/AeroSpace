import Common
import Foundation

/// Guard for the load-bearing contract of the tiling model: after any structural commit, the
/// published spine (`workspace.tilingStructureGeneration`) must describe the live dual-link tree.
///
/// That contract is currently maintained by hand — every direct live mutation is supposed to call
/// `invalidateTilingStructureGeneration()`, and every structural change is supposed to go through
/// `commitTilingTransform`. Missed invalidations are silent: the next layout renders the STALE
/// spine, so the command visually no-ops, windows snap back, and in the worst case the mismatch
/// crashes weight sync. Historically this produced a cluster of bugs (see the adversarial review:
/// `layout` commands no-oping, `move` publishing an order the live tree disagreed with, accordion
/// weight sync dying) that were individually patched — this detects the *class*.
///
/// Behavior by environment:
/// - **Unit tests**: fail loudly. A desync is a bug in the mutation site, and tests are where it
///   should surface.
/// - **Production**: never crash the WM. Record it and SELF-HEAL by dropping the generation, so
///   the next layout recaptures from live truth (the dirty-flag protocol's own fallback). A
///   silent corruption becomes a self-correcting event.
///
/// Cost is one `capture` walk (tens of nodes) per structural commit — not per frame.
@MainActor
enum SpineInvariant {
    /// Desyncs seen this session. Non-zero means some mutation site is bypassing the protocol;
    /// exposed for tests and for `debug-windows`-style diagnostics.
    private(set) static var violationCount = 0
    /// Human-readable record of the most recent violations (bounded).
    private(set) static var recentViolations: [String] = []

    /// Test seam: when set, violations are reported here INSTEAD of failing the test, so the
    /// guard itself can be tested against a deliberately desynced tree.
    static var onViolationForTests: ((String) -> Void)?

    static func resetForTests() {
        violationCount = 0
        recentViolations = []
        onViolationForTests = nil
    }

    /// Verify the published spine still matches the live tree. `context` names the mutation that
    /// just ran, so a violation points at the culprit instead of the next innocent layout.
    static func verify(_ workspace: Workspace, context: @autoclosure () -> String) {
        guard let published = workspace.tilingStructureGeneration else { return } // nothing to contradict
        let live = PersistentTilingNode.capture(workspace.rootTilingContainer)
        if live.structureEquals(published) { return }

        violationCount += 1
        let detail = """
            Spine/live desync after \(context()) on workspace \(workspace.name)
              published: \(published.debugShape)
              live:      \(live.debugShape)
            """
        if recentViolations.count >= 16 { recentViolations.removeFirst() }
        recentViolations.append(detail)

        if let hook = onViolationForTests {
            hook(detail)
        } else if isUnitTest {
            die(detail)
        } else {
            // Real usage is the only place that exercises every mutation site; append so which
            // sites actually break the contract is an observation, not a guess. Bounded by
            // truncating at ~64KB — this file is diagnostics, never unbounded growth.
            appendToLog(detail)
        }
        // Production: self-heal. Dropping the generation makes the next layout recapture from the
        // live tree, which is the observable truth the user is looking at.
        workspace.invalidateTilingStructureGeneration()
    }
}

extension SpineInvariant {
    /// `~/Library/Application Support/<appId>/spine-violations.log`
    static var logUrl: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(aeroSpaceAppId, isDirectory: true)
            .appendingPathComponent("spine-violations.log")
    }

    private static func appendToLog(_ detail: String) {
        let url = logUrl
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(detail)\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Keep it bounded: restart the file once it passes ~64KB.
            if (try? handle.seekToEnd()) ?? 0 > 64 * 1024 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

extension PersistentTilingNode {
    /// Compact shape description for diagnostics: `h.tiles[12, v.accordion[34, 56]]`.
    var debugShape: String {
        switch self {
            case .window(let id, _):
                return String(id)
            case .container(let orientation, let layout, _, let children):
                let kids = children.map(\.debugShape).joined(separator: ", ")
                return "\(orientation == .h ? "h" : "v").\(layout.rawValue)[\(kids)]"
        }
    }
}
