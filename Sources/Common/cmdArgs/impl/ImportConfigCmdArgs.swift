public struct ImportConfigCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .importConfig,
        help: import_config_help_generated,
        flags: [
            "--output": singleValueSubArgParser(\.output, "<path>", Result.success),
            "--mod": singleValueSubArgParser(\.mod4Target, "(alt|cmd)") { raw in
                raw == "alt" || raw == "cmd" ? .success(raw) : .failure("--mod must be 'alt' or 'cmd'")
            },
            "--dry-run": trueBoolFlag(\.dryRun),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.format, parseSourceFormat, placeholder: "(i3)"),
            newMandatoryPosArgParser(\.path, parsePath, placeholder: "<path>"),
        ],
    )

    public var format: Lateinit<SourceFormat> = .uninitialized
    public var path: Lateinit<String> = .uninitialized
    public var output: String? = nil
    public var mod4Target: String? = nil
    public var dryRun: Bool = false

    public enum SourceFormat: String, CaseIterable, Equatable, Sendable {
        case i3
    }
}

func parseImportConfigCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ImportConfigCmdArgs> {
    parseSpecificCmdArgs(ImportConfigCmdArgs(rawArgs: args), args)
}

private func parseSourceFormat(i: PosArgParserInput) -> ParsedCliArgs<ImportConfigCmdArgs.SourceFormat> {
    .init(parseEnum(i.arg, ImportConfigCmdArgs.SourceFormat.self), advanceBy: 1)
}

private func parsePath(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .succ(i.arg, advanceBy: 1)
}
