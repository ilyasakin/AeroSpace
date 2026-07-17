public struct AlwaysOnTopCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .alwaysOnTop,
        help: always_on_top_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )

    public var toggle: ToggleEnum = .toggle
    public var failIfNoop: Bool = false
}

func parseAlwaysOnTopCmdArgs(_ args: StrArrSlice) -> ParsedCmd<AlwaysOnTopCmdArgs> {
    parseSpecificCmdArgs(AlwaysOnTopCmdArgs(rawArgs: args), args)
        .filter("--fail-if-noop requires 'on' or 'off' argument") { $0.failIfNoop.implies($0.toggle == .on || $0.toggle == .off) }
}
