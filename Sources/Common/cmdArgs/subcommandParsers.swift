let subcommandParsers: [String: any SubCommandParserProtocol] = initSubcommands()

protocol SubCommandParserProtocol: Sendable {
    func parse(args: StrArrSlice) -> ParsedCmd<any CmdArgs>
}

struct SubCommandParser: SubCommandParserProtocol, Sendable {
    private let _parse: @Sendable (StrArrSlice) -> ParsedCmd<any CmdArgs>

    init<T: CmdArgs>(_ parser: @escaping @Sendable (StrArrSlice) -> ParsedCmd<T>) {
        _parse = { args in parser(args).map { $0 as any CmdArgs } }
    }

    init<T: CmdArgs>(_ raw: @escaping @Sendable (StrArrSlice) -> T) {
        self.init { args in parseSpecificCmdArgs(raw(args), args) }
    }

    /// Type-erased parser that may return different concrete `CmdArgs` kinds.
    init(any parser: @escaping @Sendable (StrArrSlice) -> ParsedCmd<any CmdArgs>) {
        _parse = parser
    }

    func parse(args: StrArrSlice) -> ParsedCmd<any CmdArgs> { _parse(args) }
}
