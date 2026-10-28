public struct MarkCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .mark,
        help: mark_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--add": trueBoolFlag(\.add),
            "--replace": falseBoolFlag(\.add),
            "--toggle": trueBoolFlag(\.toggle),
        ],
        posArgs: [newMandatoryPosArgParser(\.mark, parseMarkName, placeholder: "<mark>")],
        conflictingOptions: [["--add", "--replace"]],
    )

    public var mark: Lateinit<String> = .uninitialized
    public var add: Bool = false
    public var toggle: Bool = false
}

public struct UnmarkCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .unmark,
        help: unmark_help_generated,
        flags: ["--window-id": windowIdSubArgParser()],
        posArgs: [ArgParser(\.mark, upcastArgParserFun(parseMarkName))],
    )

    public var mark: String? = nil
}

public struct MoveNodeToMarkCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveNodeToMark,
        help: move_node_to_mark_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--focus-follows-window": trueBoolFlag(\.focusFollowsWindow),
        ],
        posArgs: [newMandatoryPosArgParser(\.mark, parseMarkName, placeholder: "<mark>")],
    )

    public var mark: Lateinit<String> = .uninitialized
    public var focusFollowsWindow: Bool = false
}

func parseMarkName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    i.arg.isEmpty ? .fail("<mark> must not be empty", advanceBy: 1) : .succ(i.arg, advanceBy: 1)
}

/// `criteria <criterion>... -- <command> [<arg>...]` and its i3 spelling `[criterion ...] command`
public struct CriteriaCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .criteria,
        help: criteria_help_generated,
        flags: [:],
        posArgs: [],
    )

    public var criteria: [WindowCriterion] = []
    public var command: [String] = []
}

public struct WindowCriterion: Equatable, Sendable {
    public enum Key: String, Equatable, Sendable {
        case appId = "app-id", appName = "app-name", title, windowId = "window-id", mark, workspace, floating, tiling, all
    }
    public let key: Key
    public let value: String?

    public init(key: Key, value: String?) {
        self.key = key
        self.value = value
    }

    /// i3 spellings included (`class`, `instance`, `con_id`, `id`, `con_mark`)
    public static func parse(_ term: String) -> WindowCriterion? {
        let parts = term.split(separator: "=", maxSplits: 1).map(String.init)
        let rawKey = parts.first ?? ""
        var value = parts.count > 1 ? parts[1] : nil
        if let v = value, v.count >= 2, v.first == "\"" && v.last == "\"" || v.first == "'" && v.last == "'" {
            value = String(v.dropFirst().dropLast())
        }
        let key: Key? = switch rawKey {
            case "app-id", "class", "instance": .appId
            case "app-name": .appName
            case "title": .title
            case "window-id", "con_id", "id": .windowId
            case "mark", "con_mark": .mark
            case "workspace": .workspace
            case "floating": .floating
            case "tiling": .tiling
            case "all": .all
            default: nil
        }
        guard let key else { return nil }
        let needsValue = ![.floating, .tiling, .all].contains(key)
        if needsValue != (value != nil) { return nil }
        return WindowCriterion(key: key, value: value)
    }
}

func parseCriteriaCmdArgs(_ args: StrArrSlice) -> ParsedCmd<CriteriaCmdArgs> {
    if args.first == "-h" || args.first == "--help" { return .help(CriteriaCmdArgs.info.help) }
    guard let dashDash = args.firstIndex(of: "--") else {
        return .failure("criteria: '--' followed by a command is mandatory", EXIT_CODE_TWO)
    }
    var result = CriteriaCmdArgs(rawArgs: args)
    for term in args[args.startIndex ..< dashDash] {
        guard let c = WindowCriterion.parse(term) else {
            return .failure("criteria: can't parse criterion '\(term)'", EXIT_CODE_TWO)
        }
        result.criteria.append(c)
    }
    if result.criteria.isEmpty { return .failure("criteria: at least one criterion is required", EXIT_CODE_TWO) }
    result.command = Array(args[(dashDash + 1)...])
    if result.command.isEmpty { return .failure("criteria: a command after '--' is mandatory", EXIT_CODE_TWO) }
    // Bare `focus` is i3's "focus the matched window" (it gets --window-id at run time)
    if result.command != ["focus"], case .failure(let e) = parseCmdArgs(result.command.slice) { return .failure(e) }
    return .cmd(result)
}

/// i3 prefix syntax: `[class="X" title="Y"] focus` → `criteria class=X title=Y -- focus`.
/// Words come shell-lexed, so `[class="X"` is one word and the closing `]` ends another.
public func rewriteI3CriteriaPrefix(_ words: [String]) -> [String]? {
    guard let first = words.first, first.hasPrefix("[") else { return nil }
    var terms: [String] = []
    var i = 0
    var closed = false
    while i < words.count {
        var w = words[i]
        if i == 0 { w.removeFirst() }
        if w.hasSuffix("]") {
            w.removeLast()
            closed = true
        }
        if !w.isEmpty { terms.append(w) }
        i += 1
        if closed { break }
    }
    guard closed else { return nil }
    return ["criteria"] + (terms.isEmpty ? ["all"] : terms) + ["--"] + words[i...]
}

/// String-level split of the i3 criteria prefix, BEFORE shell lexing (the lexer rejects quotes in
/// the middle of a word, and i3 writes `[class="Foo Bar"]`). Returns the criteria terms (quotes
/// around values removed) and the command text after `]`, or nil when `raw` has no prefix.
public func splitI3CriteriaPrefix(_ raw: String) -> (terms: [String], rest: String)? {
    let trimmed = raw.drop(while: { $0 == " " })
    guard trimmed.first == "[" else { return nil }
    var terms: [String] = []
    var current = ""
    var quote: Character? = nil
    var index = trimmed.index(after: trimmed.startIndex)
    while index < trimmed.endIndex {
        let ch = trimmed[index]
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == "]" {
            if !current.isEmpty { terms.append(current) }
            let rest = trimmed[trimmed.index(after: index)...].drop(while: { $0 == " " })
            return (terms.isEmpty ? ["all"] : terms, String(rest))
        } else if ch == " " {
            if !current.isEmpty { terms.append(current) }
            current = ""
        } else {
            current.append(ch)
        }
        index = trimmed.index(after: index)
    }
    return nil // unterminated
}
