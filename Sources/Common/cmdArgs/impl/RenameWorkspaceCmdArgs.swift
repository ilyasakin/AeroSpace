public struct RenameWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .renameWorkspace,
        help: rename_workspace_help_generated,
        flags: ["--workspace": workspaceSubArgParser()],
        posArgs: [
            dashDashArg(mandatory: false),
            newMandatoryPosArgParser(\.newName, { .init(WorkspaceName.parse($0.arg), advanceBy: 1) }, placeholder: "<new-name>"),
        ],
    )

    public var newName: Lateinit<WorkspaceName> = .uninitialized
}
