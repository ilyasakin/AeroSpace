private let floatingParserTable: [String: any ParserProtocol<FloatingConfig>] = [
    "click-without-raise": Parser(\.clickWithoutRaise, parseBool),
]

func parseFloating(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FloatingConfig {
    parseTable(rawConfig, FloatingConfig(), floatingParserTable, backtrace, &c)
}
