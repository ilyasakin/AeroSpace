/// M5: hyprctl-style query aliases. Default filters match hyprctl ergonomics.

// MARK: - clients → list-windows

/// Flags that already establish a list-windows scope (satisfy the mandatory filter requirement).
private let listWindowsScopeFlags: Set<String> = [
    "--all", "--focused", "--monitor", "--workspace",
]

func parseClientsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListWindowsCmdArgs> {
    // hyprctl clients ≈ list-windows over all monitors.
    // Prefer `--monitor all` over `--all` so additional filters (--pid, --app-bundle-id, …)
    // do not hit the "`--all` conflicts with filtering flags" guard.
    if !containsAnyFlag(args, listWindowsScopeFlags) {
        return parseListWindowsCmdArgs((["--monitor", "all"] + args.toArray()).slice)
    }
    return parseListWindowsCmdArgs(args)
}

func parseActiveWindowCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListWindowsCmdArgs> {
    // focused window only
    parseListWindowsCmdArgs((["--focused"] + args.toArray()).slice)
}

// MARK: - workspaces → list-workspaces

private let listWorkspacesScopeFlags: Set<String> = [
    "--all", "--focused", "--monitor",
]

func parseWorkspacesAliasCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListWorkspacesCmdArgs> {
    // Prefer `--monitor all` over `--all` so --visible/--empty stay valid.
    if !containsAnyFlag(args, listWorkspacesScopeFlags) {
        return parseListWorkspacesCmdArgs((["--monitor", "all"] + args.toArray()).slice)
    }
    return parseListWorkspacesCmdArgs(args)
}

func parseMonitorsAliasCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListMonitorsCmdArgs> {
    parseListMonitorsCmdArgs(args)
}

// MARK: - helpers

/// True if `args` contains any of `flags` as a bare token or `--flag=…` form.
func containsAnyFlag(_ args: StrArrSlice, _ flags: Set<String>) -> Bool {
    for a in args {
        if flags.contains(a) { return true }
        for flag in flags where a.hasPrefix(flag + "=") {
            return true
        }
    }
    return false
}

// MARK: - Global -j / --json (CLI preprocess, unit-testable)

/// Subcommands that accept a `--json` flag. Global `-j` only injects for these;
/// elsewhere it is a harmless no-op (hyprctl-style).
let jsonCapableSubcommands: Set<String> = [
    "list-windows", "list-workspaces", "list-monitors", "list-apps", "list-modes",
    "clients", "workspaces", "monitors", "activewindow", "binds",
    "config",
]

/// Flags that consume the next argv token as a value (so that token must not be rewritten).
private let valueTakingCliFlags: Set<String> = [
    "--format", "--workspace", "--monitor", "--window-id", "--pid",
    "--app-bundle-id", "--app-id", "--get", "--mod", "--output",
    "--boundaries", "--boundaries-action", "--dfs-index",
]

/// Strip leading global `-j`/`--json`, rewrite short `-j` only in flag positions, and inject
/// `--json` only for JSON-capable subcommands.
public func preprocessAerospaceCliArgs(_ raw: [String]) -> [String] {
    var args = raw
    var forceJson = false
    while let first = args.first, first == "-j" || first == "--json" {
        forceJson = true
        args.removeFirst()
    }
    guard !args.isEmpty else { return args }

    args = rewriteShortJsonFlagInFlagPositions(args)

    let sub = args[0]
    if forceJson, jsonCapableSubcommands.contains(sub), !args.contains("--json") {
        args.insert("--json", at: 1)
    }
    return args
}

/// Rewrite bare `-j` → `--json` only when the previous token is not a value-taking flag.
/// Does not rewrite values such as `--format -j` or positional free text after such flags.
public func rewriteShortJsonFlagInFlagPositions(_ args: [String]) -> [String] {
    guard !args.isEmpty else { return args }
    var result: [String] = [args[0]] // subcommand never rewritten
    var i = 1
    while i < args.count {
        let token = args[i]
        let prev = result.last ?? args[0]
        let prevTakesValue = valueTakingCliFlags.contains(prev)
            || (prev.hasPrefix("-") && !prev.hasPrefix("--") && prev.count == 2 && prev != "-j")
        // Only rewrite when `-j` is a free-standing flag, not a value of the previous option
        if token == "-j", !prevTakesValue {
            result.append("--json")
        } else {
            result.append(token)
        }
        i += 1
    }
    return result
}
