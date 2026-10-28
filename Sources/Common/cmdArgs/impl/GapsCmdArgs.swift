public struct GapsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gaps,
        help: gaps_help_generated,
        flags: ["--workspace": workspaceSubArgParser()],
        posArgs: [
            newMandatoryPosArgParser(\.type, { .init(parseEnum($0.arg, GapType.self), advanceBy: 1) }, placeholder: GapType.unionLiteral),
            newMandatoryPosArgParser(\.scope, { .init(parseEnum($0.arg, Scope.self), advanceBy: 1) }, placeholder: Scope.unionLiteral),
            newMandatoryPosArgParser(\.operation, { .init(parseEnum($0.arg, Operation.self), advanceBy: 1) }, placeholder: Operation.unionLiteral),
            newMandatoryPosArgParser(\.pixels, { i in
                let raw = i.arg.hasSuffix("px") ? String(i.arg.dropLast(2)) : i.arg
                return UInt(raw).map { .succ($0, advanceBy: 1) } ?? .fail("<px> must be a non-negative number", advanceBy: 1)
            }, placeholder: "<px>"),
        ],
    )

    public var type: Lateinit<GapType> = .uninitialized
    public var scope: Lateinit<Scope> = .uninitialized
    public var operation: Lateinit<Operation> = .uninitialized
    public var pixels: Lateinit<UInt> = .uninitialized

    public enum GapType: String, CaseIterable, Equatable, Sendable {
        case inner, outer, horizontal, vertical, top, right, bottom, left
    }
    public enum Scope: String, CaseIterable, Equatable, Sendable {
        case current, all
    }
    public enum Operation: String, CaseIterable, Equatable, Sendable {
        case set, plus, minus, toggle
    }
}
