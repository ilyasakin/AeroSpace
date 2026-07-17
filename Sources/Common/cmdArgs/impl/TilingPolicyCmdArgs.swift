public struct TilingPolicyCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .tilingPolicy,
        help: tiling_policy_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.target, parseTilingPolicyTarget, placeholder: "(manual|dwindle|default)"),
        ],
    )

    public var target: Lateinit<Target> = .uninitialized

    public enum Target: String, CaseIterable, Equatable, Sendable {
        case manual
        case dwindle
        /// Drop the per-workspace override and follow the config again
        case `default`
    }
}

func parseTilingPolicyCmdArgs(_ args: StrArrSlice) -> ParsedCmd<TilingPolicyCmdArgs> {
    parseSpecificCmdArgs(TilingPolicyCmdArgs(rawArgs: args), args)
}

private func parseTilingPolicyTarget(i: PosArgParserInput) -> ParsedCliArgs<TilingPolicyCmdArgs.Target> {
    .init(parseEnum(i.arg, TilingPolicyCmdArgs.Target.self), advanceBy: 1)
}
