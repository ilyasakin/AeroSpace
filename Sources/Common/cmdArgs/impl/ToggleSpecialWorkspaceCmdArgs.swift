public struct ToggleSpecialWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .toggleSpecialWorkspace,
        help: toggle_special_workspace_help_generated,
        flags: [:],
        posArgs: [
            dashDashArg(mandatory: false),
            newMandatoryPosArgParser(\.target, parseWorkspaceNameArg, placeholder: "<workspace>"),
        ],
    )

    public var target: Lateinit<WorkspaceName> = .uninitialized
}

private func parseWorkspaceNameArg(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceName> {
    .init(WorkspaceName.parse(i.arg), advanceBy: 1)
}
