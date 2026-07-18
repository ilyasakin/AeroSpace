import Common
import Foundation

/// First-party status bar config (opt-in). See `dev-docs/first-party-bar-brief.md`.
struct StatusBarConfig: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    /// Bar height in points below the system menu bar.
    var height: Int = 28
    /// Built-in module ids, left-to-right. Known: workspaces, mode, focused, clock, battery, cpu, memory, volume, network
    var modulesLeft: [String] = ["workspaces", "mode", "focused"]
    var modulesRight: [String] = ["clock", "battery"]
    /// When true, the workspaces module omits empty (unoccupied) workspaces — except the focused one.
    var hideEmptyWorkspaces: Bool = false
    /// When true, the `focused` module draws the current app's Dock icon next to its name.
    var focusedShowIcon: Bool = false
    /// Optional display labels for the workspaces module: workspace name → letter/symbol/emoji.
    /// Unmapped workspaces still show their real name. Clicks always use the real name.
    var workspaceSymbols: [String: String] = [:]
    /// Optional external process that speaks the i3bar protocol on stdout.
    var statusCommand: [String] = []
    var background: String = "#1e1e2e"
    var foreground: String = "#cdd6f4"
    var focusedBackground: String = "#89b4fa"
    var focusedForeground: String = "#1e1e2e"
    var fontSize: Int = 12
    /// `strftime`-style clock format (e.g. `%H:%M`, `%d/%m %H:%M`). Sketchybar-compatible subset.
    var clockFormat: String = "%H:%M"

    static let disabled = StatusBarConfig()
}

private let statusBarParser: [String: any ParserProtocol<StatusBarConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parseInt),
    "modules-left": Parser(\.modulesLeft, parseArrayOfStrings),
    "modules-right": Parser(\.modulesRight, parseArrayOfStrings),
    "hide-empty-workspaces": Parser(\.hideEmptyWorkspaces, parseBool),
    "focused-show-icon": Parser(\.focusedShowIcon, parseBool),
    "workspace-symbols": Parser(\.workspaceSymbols, parseWorkspaceSymbols),
    "status-command": Parser(\.statusCommand, parseArrayOfStrings),
    "background": Parser(\.background, parseString),
    "foreground": Parser(\.foreground, parseString),
    "focused-background": Parser(\.focusedBackground, parseString),
    "focused-foreground": Parser(\.focusedForeground, parseString),
    "font-size": Parser(\.fontSize, parseInt),
    "clock-format": Parser(\.clockFormat, parseString),
]

func parseStatusBar(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> StatusBarConfig {
    parseTable(raw, StatusBarConfig(), statusBarParser, backtrace, &c)
}

/// `[bar.workspace-symbols]` map: workspace name → bar label (letter, symbol, emoji, short text).
func parseWorkspaceSymbols(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> [String: String] {
    guard let table = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: String] = [:]
    for (workspace, value) in table {
        let bt = backtrace + .key(workspace)
        if let s = value.asStringOrNil {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result[workspace] = trimmed
            }
        } else if let i = value.asIntOrNil {
            // Bare TOML integers as labels are allowed (`1 = 一` is string; `1 = 2` is int).
            result[workspace] = String(i)
        } else {
            c.errors += [expectedActualTypeDiagnostic(expected: [.string, .int], actual: value.tomlType, bt)]
        }
    }
    return result
}

/// Label shown on the bar for a workspace. Empty/missing mapping falls back to the real name.
func statusBarWorkspaceLabel(name: String, symbols: [String: String]) -> String {
    if let label = symbols[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
        return label
    }
    return name
}
