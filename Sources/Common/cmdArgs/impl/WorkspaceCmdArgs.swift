public struct WorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspace,
        help: workspace_help_generated,
        flags: [
            "--auto-back-and-forth": ArgParser(\._autoBackAndForth, constSubArgParserFun(true)),
            "--no-auto-back-and-forth": ArgParser(\._autoBackAndForth, constSubArgParserFun(false)),
            "--wrap-around": ArgParser(\._wrapAround, constSubArgParserFun(true)),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--all-monitors": trueBoolFlag(\.allMonitors),
            "--number": trueBoolFlag(\.number),

            "--stdin": ArgParser(\.commonState.explicitStdinFlag, constSubArgParserFun(true)),
            "--no-stdin": ArgParser(\.commonState.explicitStdinFlag, constSubArgParserFun(false)),
        ],
        posArgs: [
            dashDashArg(mandatory: false),
            newMandatoryPosArgParser(\.target, parseWorkspaceTarget, placeholder: workspaceTargetPlaceholder),
        ],
        conflictingOptions: [
            ["--stdin", "--no-stdin"],
            ["--auto-back-and-forth", "--no-auto-back-and-forth"],
        ],
    )

    public var target: Lateinit<WorkspaceTarget> = .uninitialized
    public var _autoBackAndForth: Bool?
    public var failIfNoop: Bool = false
    public var _wrapAround: Bool?
    /// i3 `workspace next` (every monitor) vs the default `next_on_output`
    public var allMonitors: Bool = false
    /// i3 `workspace number N`: the workspace whose name starts with the number N ("3:mail")
    public var number: Bool = false
}

func parseWorkspaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WorkspaceCmdArgs> {
    parseSpecificCmdArgs(WorkspaceCmdArgs(rawArgs: args), args)
        .filter("--wrapAround requires using \(NextPrev.unionLiteral) argument") { ($0._wrapAround != nil).implies($0.target.val.isRelatve) }
        .filterNot("--auto-back-and-forth is incompatible with \(NextPrev.unionLiteral)") { $0._autoBackAndForth != nil && $0.target.val.isRelatve }
        .filterNot("--fail-if-noop is incompatible with \(NextPrev.unionLiteral)") { $0.failIfNoop && $0.target.val.isRelatve }
        .filterNot("--fail-if-noop is incompatible with --auto-back-and-forth") { $0.autoBackAndForth && $0.failIfNoop }
        .filter("--stdin and --no-stdin require using \(NextPrev.unionLiteral) argument") { ($0.commonState.explicitStdinFlag != nil).implies($0.target.val.isRelatve) }
        .filter("--all-monitors requires using \(NextPrev.unionLiteral) argument") { $0.allMonitors.implies($0.target.val.isRelatve) }
        .filter("--number requires a workspace name that starts with a number") {
            $0.number.implies($0.target.val.workspaceNameOrNil()?.raw.first?.isNumber == true)
        }
}

extension WorkspaceCmdArgs {
    public var wrapAround: Bool { _wrapAround ?? false }
    public var autoBackAndForth: Bool { _autoBackAndForth ?? false }
    public var useStdin: Bool { commonState.explicitStdinFlag ?? false }
}

public enum WorkspaceTarget: Equatable, Sendable {
    case relative(NextPrev)
    case direct(WorkspaceName)
    /// The previously focused workspace (i3 `back_and_forth` as a target)
    case backAndForth

    public var isRelatve: Bool {
        switch self {
            case .relative: true
            default: false
        }
    }

    public func workspaceNameOrNil() -> WorkspaceName? {
        switch self {
            case .direct(let name): name
            case .relative, .backAndForth: nil
        }
    }
}

let workspaceTargetPlaceholder = "(<workspace-name>|next|prev|back-and-forth)"

func parseWorkspaceTarget(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceTarget> {
    switch (i.arg, i.sawDashDash) {
        case ("next", false): return .succ(.relative(.next), advanceBy: 1)
        case ("prev", false): return .succ(.relative(.prev), advanceBy: 1)
        case ("back-and-forth", false): return .succ(.backAndForth, advanceBy: 1)
        default: return .init(WorkspaceName.parse(i.arg).map(WorkspaceTarget.direct), advanceBy: 1)
    }
}
