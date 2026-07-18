public struct ResizeToCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .resizeTo,
        help: resize_to_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.width, parsePixelArg, placeholder: "<width>"),
            newMandatoryPosArgParser(\.height, parsePixelArg, placeholder: "<height>"),
        ],
    )

    public var width: Lateinit<UInt> = .uninitialized
    public var height: Lateinit<UInt> = .uninitialized
}

func parseResizeToCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ResizeToCmdArgs> {
    parseSpecificCmdArgs(ResizeToCmdArgs(rawArgs: args), args)
}

private func parsePixelArg(i: PosArgParserInput) -> ParsedCliArgs<UInt> {
    guard let value = UInt(i.arg), value > 0 else {
        return .fail("<width>/<height> must be a positive integer", advanceBy: 1)
    }
    return .succ(value, advanceBy: 1)
}
