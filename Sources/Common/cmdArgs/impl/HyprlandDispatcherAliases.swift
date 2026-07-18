/// Hyprland dispatcher-name surface (M1). Maps Hyprland verbs onto existing AeroSpace `CmdArgs`
/// without new `CmdKind`s. Normalization mirrors `HyprImporter.mapDispatcher`.

// MARK: - Direction helpers (shared by movefocus / movewindow / swapwindow / monitors)

func mapHyprlandDirection(_ arg: String) -> String? {
    switch arg.lowercased() {
        case "l", "left": "left"
        case "r", "right": "right"
        case "u", "up": "up"
        case "d", "down": "down"
        case "next": "next"
        case "prev", "previous": "prev"
        default: nil
    }
}

private func rewriteDirectionArg(_ args: StrArrSlice) -> Result<StrArrSlice, String> {
    guard let first = args.first else {
        return .failure("direction argument is mandatory")
    }
    guard let mapped = mapHyprlandDirection(first) else {
        return .failure("can't parse direction '\(first)'")
    }
    var rewritten = args.toArray()
    rewritten[0] = mapped
    return .success(rewritten.slice)
}

// MARK: - Pure-arg rewrites

func parseHyprlandToggleFloatingCmdArgs(_ args: StrArrSlice) -> ParsedCmd<LayoutCmdArgs> {
    if !args.isEmpty {
        return .failure("togglefloating takes no arguments")
    }
    return parseLayoutCmdArgs(["floating", "tiling"].slice)
}

func parseHyprlandToggleSplitCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SplitCmdArgs> {
    if !args.isEmpty {
        return .failure("togglesplit takes no arguments")
    }
    return parseSplitCmdArgs(["opposite"].slice)
}

func parseHyprlandCycleNextCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusCmdArgs> {
    if !args.isEmpty {
        return .failure("cyclenext takes no arguments")
    }
    return parseFocusCmdArgs(["dfs-next"].slice)
}

func parseHyprlandMoveFocusCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusCmdArgs> {
    switch rewriteDirectionArg(args) {
        case .failure(let msg): .failure(msg)
        case .success(let rewritten): parseFocusCmdArgs(rewritten)
    }
}

func parseHyprlandMoveWindowCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveCmdArgs> {
    switch rewriteDirectionArg(args) {
        case .failure(let msg): .failure(msg)
        case .success(let rewritten): parseMoveCmdArgs(rewritten)
    }
}

func parseHyprlandFocusMonitorCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusMonitorCmdArgs> {
    switch rewriteDirectionArg(args) {
        case .failure(let msg): .failure(msg)
        case .success(let rewritten): parseFocusMonitorCmdArgs(rewritten)
    }
}

func parseHyprlandMoveCurrentWorkspaceToMonitorCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveWorkspaceToMonitorCmdArgs> {
    switch rewriteDirectionArg(args) {
        case .failure(let msg): .failure(msg)
        case .success(let rewritten): parseWorkspaceToMonitorCmdArgs(rewritten)
    }
}

func parseHyprlandSubmapCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ModeCmdArgs> {
    guard let name = args.first else {
        return .failure("submap requires a mode name (or 'reset')")
    }
    if args.count > 1 {
        return .failure("Unknown argument '\(args[1])'")
    }
    let mode = name == "reset" ? "main" : name
    return parseModeCmdArgs([mode].slice)
}

func parseHyprlandExecCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ExecAndForgetCmdArgs> {
    if args.isEmpty {
        return .failure("exec requires a command")
    }
    // Join remaining tokens the same way the shell would for a free-form script tail.
    let script = " " + args.toArray().joined(separator: " ")
    return .cmd(ExecAndForgetCmdArgs(bashScript: script))
}

func parseHyprlandResizeActiveCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ResizeCmdArgs> {
    let tokens = args.toArray()
    // Accept "50 0", "50,0", or two separate argv tokens.
    let numbers: [Int]
    if tokens.count == 1 {
        numbers = tokens[0].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
    } else if tokens.count == 2 {
        guard let x = Int(tokens[0]), let y = Int(tokens[1]) else {
            return .failure("can't parse resizeactive arguments")
        }
        numbers = [x, y]
    } else {
        return .failure("can't parse resizeactive arguments")
    }
    guard numbers.count == 2 else {
        return .failure("can't parse resizeactive arguments")
    }
    let x = numbers[0]
    let y = numbers[1]
    if x == 0 && y == 0 {
        return .failure("resizeactive 0 0 is a no-op")
    }
    if x != 0 && y != 0 {
        return .failure(
            "resizeactive with both dimensions non-zero can't be a single CLI command; " +
                "use 'resize width \(signedUnits(x)) && resize height \(signedUnits(y))'",
        )
    }
    if x != 0 {
        return parseResizeCmdArgs(["width", signedUnits(x)].slice)
    }
    return parseResizeCmdArgs(["height", signedUnits(y)].slice)
}

private func signedUnits(_ value: Int) -> String {
    value > 0 ? "+\(value)" : "-\(abs(value))"
}

// MARK: - Workspace family (Hyprland-only command names; never widen canonical `workspace`)

func parseHyprlandMoveToWorkspaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveNodeToWorkspaceCmdArgs> {
    guard let first = args.first else {
        return parseMoveNodeToWorkspaceCmdArgs(args)
    }
    var rewritten = args.toArray()
    // special / special:name → move-node-to-workspace <name> (same as importer)
    // Safe: `movetoworkspace` is not an AeroSpace command name.
    if first.hasPrefix("special") {
        rewritten[0] = hyprlandSpecialWorkspaceName(first)
    } else if rewritten[0].hasPrefix("name:") {
        rewritten[0] = String(rewritten[0].dropFirst("name:".count))
    }
    return parseMoveNodeToWorkspaceCmdArgs(rewritten.slice)
}

/// Hyprland `togglespecialworkspace [name]` → toggle-special-workspace.
/// Accepts bare name (`magic`) or `special` / `special:magic` (same as importer).
/// No arg → workspace name `special` (Hyprland default special workspace).
func parseHyprlandToggleSpecialWorkspaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ToggleSpecialWorkspaceCmdArgs> {
    if args.isEmpty {
        return parseToggleSpecialWorkspaceCmdArgs(["special"].slice)
    }
    guard let first = args.first else {
        return parseToggleSpecialWorkspaceCmdArgs(["special"].slice)
    }
    if args.count > 1 {
        return .failure("Unknown argument '\(args[1])'")
    }
    let name = first.hasPrefix("special")
        ? hyprlandSpecialWorkspaceName(first)
        : first.filter { !$0.isWhitespace }
    return parseToggleSpecialWorkspaceCmdArgs([name].slice)
}

/// `special`, `special:magic` → workspace name used by toggle-special-workspace / move-node-to-workspace
func hyprlandSpecialWorkspaceName(_ arg: String) -> String {
    if arg == "special" { return "special" }
    if arg.hasPrefix("special:") {
        let rest = String(arg.dropFirst("special:".count)).filter { !$0.isWhitespace }
        return rest.isEmpty ? "special" : rest
    }
    return arg.filter { !$0.isWhitespace }
}

func parseToggleSpecialWorkspaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ToggleSpecialWorkspaceCmdArgs> {
    parseSpecificCmdArgs(ToggleSpecialWorkspaceCmdArgs(rawArgs: args), args)
}

// ModeCmdArgs parser is the default struct init via parseSpecificCmdArgs — expose a named fn
func parseModeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ModeCmdArgs> {
    parseSpecificCmdArgs(ModeCmdArgs(rawArgs: args), args)
}
