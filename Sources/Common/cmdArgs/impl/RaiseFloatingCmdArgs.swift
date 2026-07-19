public struct RaiseFloatingCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .raiseFloating,
        help: raise_floating_help_generated,
        flags: [:],
        posArgs: [],
    )
}
