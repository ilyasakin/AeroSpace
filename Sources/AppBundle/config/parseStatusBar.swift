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
    /// Optional external process that speaks the i3bar protocol on stdout.
    var statusCommand: [String] = []
    var background: String = "#1e1e2e"
    var foreground: String = "#cdd6f4"
    var focusedBackground: String = "#89b4fa"
    var focusedForeground: String = "#1e1e2e"
    var fontSize: Int = 12

    static let disabled = StatusBarConfig()
}

private let statusBarParser: [String: any ParserProtocol<StatusBarConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parseInt),
    "modules-left": Parser(\.modulesLeft, parseArrayOfStrings),
    "modules-right": Parser(\.modulesRight, parseArrayOfStrings),
    "hide-empty-workspaces": Parser(\.hideEmptyWorkspaces, parseBool),
    "status-command": Parser(\.statusCommand, parseArrayOfStrings),
    "background": Parser(\.background, parseString),
    "foreground": Parser(\.foreground, parseString),
    "focused-background": Parser(\.focusedBackground, parseString),
    "focused-foreground": Parser(\.focusedForeground, parseString),
    "font-size": Parser(\.fontSize, parseInt),
]

func parseStatusBar(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> StatusBarConfig {
    parseTable(raw, StatusBarConfig(), statusBarParser, backtrace, &c)
}
