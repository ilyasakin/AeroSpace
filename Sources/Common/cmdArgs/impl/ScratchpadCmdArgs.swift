public struct ScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpad,
        help: scratchpad_help_generated,
        flags: ["--window-id": windowIdSubArgParser()],
        posArgs: [newMandatoryPosArgParser(\.action, { .init(parseEnum($0.arg, ScratchpadAction.self), advanceBy: 1) }, placeholder: ScratchpadAction.unionLiteral)],
    )

    public var action: Lateinit<ScratchpadAction> = .uninitialized

    public enum ScratchpadAction: String, CaseIterable, Equatable, Sendable {
        case show, move
    }
}
