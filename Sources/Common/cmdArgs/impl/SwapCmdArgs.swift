public struct SwapCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .swap,
        help: swap_help_generated,
        flags: [
            "--swap-focus": trueBoolFlag(\.swapFocus),
            "--wrap-around": trueBoolFlag(\.wrapAround),
            "--window-id": windowIdSubArgParser(),
            "--with-mark": singleValueSubArgParser(\.withMark, "<mark>", { .success($0) }),
        ],
        posArgs: [ArgParser(\.target, upcastArgParserFun(parseCardinalOrDfsDirection))],
    )

    public var target: CardinalOrDfsDirection? = nil
    /// i3 `swap container with mark <mark>`
    public var withMark: String? = nil
    public var swapFocus: Bool = false
    public var wrapAround: Bool = false
}

func parseSwapCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SwapCmdArgs> {
    return parseSpecificCmdArgs(SwapCmdArgs(rawArgs: args), args)
        .filter("Argument '\(CardinalOrDfsDirection.unionLiteral)' or --with-mark is mandatory") { $0.target != nil || $0.withMark != nil }
        .filter("--with-mark is incompatible with a direction") { $0.target == nil || $0.withMark == nil }
}
