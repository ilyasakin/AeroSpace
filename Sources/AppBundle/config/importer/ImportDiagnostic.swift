import Foundation

/// A single finding produced while importing a foreign (i3/Hyprland) config
struct ImportDiagnostic: Equatable {
    enum Severity: String, Equatable {
        /// Translated, but semantics differ slightly (e.g. tabbed -> accordion)
        case note
        /// Not translated. The original line is preserved as a comment in the output
        case skipped
    }

    let severity: Severity
    let lineNumber: Int
    /// The original line from the source config, trimmed
    let original: String
    let reason: String

    var description: String {
        "line \(lineNumber): [\(severity.rawValue)] \(original) — \(reason)"
    }
}

struct ImportResult {
    let toml: String
    let diagnostics: [ImportDiagnostic]
    /// Total number of meaningful directives found in the source config
    let directiveCount: Int

    var skippedCount: Int { diagnostics.count { $0.severity == .skipped } }
    var translatedCount: Int { directiveCount - skippedCount }
}

struct ImportOptions {
    /// What i3's Mod4/$mod (Super) maps to. Mod1 (Alt) always maps to 'alt';
    /// when a config uses BOTH Mod1 and Mod4, Mod4 falls back to 'cmd' regardless of this setting
    var mod4Target: String = "alt"
    /// Reads an included file (i3 'include' directive). Injected for testability
    var readIncludedFile: (String) -> String? = { path in
        try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    }
}
