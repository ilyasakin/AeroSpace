import Common

func parseCommand(
    _ raw: String,
    allowExecAndForget: Bool,
    allowEval: Bool,
) -> ParsedCmd<Shell<any Command>> {
    if allowExecAndForget {
        if raw.starts(with: "exec-and-forget") {
            return .cmd(.cmd(ExecAndForgetCommand(args: ExecAndForgetCmdArgs(bashScript: raw.removePrefix("exec-and-forget")))))
        }
        // Hyprland dispatcher alias for exec-and-forget (M1). Match whole token "exec" only.
        if raw == "exec" || raw.starts(with: "exec ") {
            return .cmd(.cmd(ExecAndForgetCommand(args: ExecAndForgetCmdArgs(bashScript: raw.removePrefix("exec")))))
        }
    }
    // i3 criteria prefix: `[class="Foo Bar"] focus` → criteria `class=Foo Bar` -- focus. The words
    // are handed over as an array (no re-quoting), and the prefix applies to every command of the
    // rest (`[..] move left && focus` targets the match twice)
    if let (terms, rest) = splitI3CriteriaPrefix(raw) {
        return switch rest.lexAndParseShell() {
            case .success(let it):
                it.flatMap { words in
                    switch parseCommand(["criteria"] + terms + ["--"] + words) {
                        case .cmd(let it): .cmd(it)
                        case .failure(let it): .failure(it)
                        case .help(let it): .help(it)
                    }
                }
            case .failure(let it): ParsedCmd.failure(it, EXIT_CODE_TWO)
        }
    }
    return switch raw.lexAndParseShell() {
        case .success(let it):
            it.flatMap { args in
                switch parseCommand(args) {
                    case .cmd(_ as EvalCommand) where !allowEval: .failure("Illegal eval (Tip: nested evals are forbidden)", EXIT_CODE_TWO)
                    case .cmd(let it): .cmd(it)
                    case .failure(let it): .failure(it)
                    case .help(let it): .help(it)
                }
            }
        case .failure(let it): ParsedCmd.failure(it, EXIT_CODE_TWO)
    }
}

func parseCommand(_ args: [String]) -> ParsedCmd<any Command> {
    // i3 criteria prefix: `[class="X"] focus` → `criteria class=X -- focus`
    let args = rewriteI3CriteriaPrefix(args) ?? args
    return parseCmdArgs(args.slice).flatMap { $0.toCommand() }
}

func expectedActualTypeError(expected: TomlType, actual: TomlType) -> String {
    "Expected type is \(expected.rawValue.singleQuoted). But actual type is \(actual.rawValue.singleQuoted)"
}

func expectedActualTypeError(expected: [TomlType], actual: TomlType) -> String {
    switch expected.singleOrNil() {
        case let single?: expectedActualTypeError(expected: single, actual: actual)
        case nil: "Expected types are \(expected.map { "'\($0)'" }.joined(separator: " or ")). But actual type is '\(actual)'"
    }
}
