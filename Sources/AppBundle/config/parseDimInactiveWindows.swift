private let dimInactiveWindowsParserTable: [String: any ParserProtocol<DimInactiveWindows>] = [
    "enabled": Parser(\.enabled, parseBool),
    "amount": Parser(\.amount, parseInt),
]

func parseDimInactiveWindows(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> DimInactiveWindows {
    parseTable(rawConfig, DimInactiveWindows(), dimInactiveWindowsParserTable, backtrace, &c)
}
