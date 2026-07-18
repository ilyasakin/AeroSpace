public struct MoveToCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveTo,
        help: move_to_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.x, parseCoordArg, placeholder: "<x>"),
            newMandatoryPosArgParser(\.y, parseCoordArg, placeholder: "<y>"),
        ],
    )

    public var x: Lateinit<Int> = .uninitialized
    public var y: Lateinit<Int> = .uninitialized
}

func parseMoveToCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveToCmdArgs> {
    parseSpecificCmdArgs(MoveToCmdArgs(rawArgs: args), args)
}

private func parseCoordArg(i: PosArgParserInput) -> ParsedCliArgs<Int> {
    guard let value = Int(i.arg) else {
        return .fail("<x>/<y> must be an integer", advanceBy: 1)
    }
    return .succ(value, advanceBy: 1)
}
