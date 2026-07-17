import Foundation

/// Translates an i3 (i3wm / i3-gaps) config into a native config + compatibility diagnostics.
/// Pure: no IO except includes, which go through options.readIncludedFile
func importI3Config(_ text: String, _ options: ImportOptions = ImportOptions()) -> ImportResult {
    var ctx = I3ImportContext(options: options)
    ctx.parseLines(text)
    let toml = emitAeroToml(builder: ctx.builder, diagnostics: ctx.diagnostics, sourceKind: "i3")
    return ImportResult(toml: toml, diagnostics: ctx.diagnostics, directiveCount: ctx.directiveCount)
}

struct AeroConfigBuilder {
    /// mode name -> ordered [(binding, [commands])]
    var bindings: [(mode: String, key: String, commands: [String])] = []
    var modeNames: [String] = ["main"]
    var startupCommands: [String] = []
    var focusFollowsMouse: Bool? = nil
    var defaultLayout: String? = nil
    var defaultOrientation: String? = nil
    var gapsInner: [String: Int] = [:] // vertical/horizontal
    var gapsOuter: [String: Int] = [:] // left/bottom/top/right
    var workspaceToMonitor: [(workspace: String, output: String)] = []
    var detectionRules: [(matchers: [String], treatAs: String)] = []
    var windowCallbacks: [(matchers: [String], run: [String])] = []
}

private struct I3ImportContext {
    let options: ImportOptions
    var builder = AeroConfigBuilder()
    var diagnostics: [ImportDiagnostic] = []
    var directiveCount = 0
    var variables: [String: String] = [:]
    var usesMod1 = false
    var usesMod4 = false

    var mod4Target: String {
        usesMod1 && usesMod4 ? "cmd" : options.mod4Target
    }

    mutating func skip(_ line: Int, _ original: String, _ reason: String) {
        diagnostics.append(ImportDiagnostic(severity: .skipped, lineNumber: line, original: original, reason: reason))
    }

    mutating func note(_ line: Int, _ original: String, _ reason: String) {
        diagnostics.append(ImportDiagnostic(severity: .note, lineNumber: line, original: original, reason: reason))
    }

    // MARK: Parsing

    mutating func parseLines(_ text: String) {
        // Join line continuations first, remembering original line numbers
        var logicalLines: [(number: Int, text: String)] = []
        var pending = ""
        var pendingStart = 0
        for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if pending.isEmpty { pendingStart = i + 1 }
            if line.hasSuffix("\\") {
                pending += String(line.dropLast())
                continue
            }
            pending += line
            logicalLines.append((pendingStart, pending))
            pending = ""
        }
        if !pending.isEmpty { logicalLines.append((pendingStart, pending)) }

        // Pre-scan for modifier usage ($mod resolution must be known before mapping bindings)
        for (_, line) in logicalLines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("set ") { registerVariable(t) }
        }
        for (_, line) in logicalLines {
            let expanded = expandVariables(line)
            if expanded.contains("Mod1") { usesMod1 = true }
            if expanded.contains("Mod4") { usesMod4 = true }
        }
        variables = [:]

        var mode = "main"
        var barDepth = 0
        var i = 0
        while i < logicalLines.count {
            let (lineNo, raw) = logicalLines[i]
            i += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if barDepth > 0 {
                barDepth += trimmed.count { $0 == "{" }
                barDepth -= trimmed.count { $0 == "}" }
                continue
            }

            if trimmed == "}" {
                mode = "main"
                continue
            }

            let expanded = expandVariables(trimmed)
            directiveCount += 1
            handleDirective(expanded, original: trimmed, line: lineNo, mode: &mode, barDepth: &barDepth)
        }
    }

    mutating func registerVariable(_ line: String) {
        // set $name value...
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "set", parts[1].hasPrefix("$") else { return }
        variables[parts[1]] = parts.dropFirst(2).joined(separator: " ")
    }

    func expandVariables(_ line: String) -> String {
        var result = line
        // Longest variable names first so $ws10 wins over $ws1
        for (name, value) in variables.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: name, with: value)
        }
        return result
    }

    mutating func handleDirective(_ line: String, original: String, line lineNo: Int, mode: inout String, barDepth: inout Int) {
        let (word, rest) = line.splitFirstWord()

        switch word {
            case "set":
                registerVariable(line)
                directiveCount -= 1 // variables are bookkeeping, not directives
            case "bindsym":
                handleBindsym(rest, original: original, line: lineNo, mode: mode)
            case "bindcode":
                skip(lineNo, original, "key codes (bindcode) are not supported; rewrite as bindsym")
            case "mode":
                var name = rest.trimmingCharacters(in: .whitespaces)
                name = name.removeSuffixIfPresent("{").trimmingCharacters(in: .whitespaces)
                name = name.removePrefixIfPresent("--pango_markup").trimmingCharacters(in: .whitespaces)
                name = name.unquoted()
                mode = name == "default" ? "main" : name
                if mode != "main", !builder.modeNames.contains(mode) { builder.modeNames.append(mode) }
                directiveCount -= 1
            case "bar":
                let braces = rest.count(where: { $0 == "{" }) - rest.count(where: { $0 == "}" })
                barDepth = max(braces, 1) // 'bar {' opens exactly one block even though '{' is part of rest
                skip(lineNo, original, "no i3bar on macOS; see the sketchybar integration recipe in the guide")
            case "exec", "exec_always":
                let cmd = rest.removePrefixIfPresent("--no-startup-id").trimmingCharacters(in: .whitespaces)
                builder.startupCommands.append("exec-and-forget \(cmd)")
            case "for_window":
                handleForWindow(rest, original: original, line: lineNo)
            case "assign":
                handleAssign(rest, original: original, line: lineNo)
            case "workspace":
                handleWorkspaceDirective(rest, original: original, line: lineNo)
            case "gaps":
                handleGaps(rest, original: original, line: lineNo)
            case "focus_follows_mouse":
                builder.focusFollowsMouse = rest.trimmingCharacters(in: .whitespaces) != "no"
            case "workspace_layout":
                let value = rest.trimmingCharacters(in: .whitespaces)
                if value == "default" {
                    builder.defaultLayout = "tiles"
                } else {
                    builder.defaultLayout = "accordion"
                    note(lineNo, original, "'\(value)' approximated as accordion (closest analog of stacking/tabbed)")
                }
            case "default_orientation":
                let value = rest.trimmingCharacters(in: .whitespaces)
                builder.defaultOrientation = value == "auto" ? "auto" : (value == "vertical" ? "vertical" : "horizontal")
            case "include":
                directiveCount -= 1
                let path = rest.trimmingCharacters(in: .whitespaces).unquoted()
                if let included = options.readIncludedFile(path) {
                    parseLines(included)
                } else {
                    skip(lineNo, original, "included file couldn't be read at import time")
                }
            case "floating_modifier":
                skip(lineNo, original, "floating windows are dragged natively on macOS; no drag modifier needed")
            case "font", "title_format":
                skip(lineNo, original, "window titles/fonts are drawn by macOS, not the window manager")
            case "default_border", "default_floating_border", "new_window", "new_float", "hide_edge_borders", "smart_borders":
                skip(lineNo, original, "no window borders on macOS; see the JankyBorders recipe in the guide")
            case "smart_gaps":
                skip(lineNo, original, "smart gaps are not supported")
            case "workspace_auto_back_and_forth", "focus_wrapping", "force_focus_wrapping", "mouse_warping",
                 "popup_during_fullscreen", "force_display_urgency_hint", "focus_on_window_activation",
                 "show_marks", "tiling_drag", "ipc-socket", "ipc_socket", "restart_state",
                 "floating_minimum_size", "floating_maximum_size":
                skip(lineNo, original, "behavior tweak with no equivalent")
            default:
                if word.hasPrefix("client.") {
                    skip(lineNo, original, "window decoration colors are not drawn on macOS; see the JankyBorders recipe")
                } else {
                    skip(lineNo, original, "unrecognized directive")
                }
        }
    }

    // MARK: bindsym

    mutating func handleBindsym(_ rest: String, original: String, line: Int, mode: String) {
        var rest = rest.trimmingCharacters(in: .whitespaces)
        while rest.hasPrefix("--") { // --release, --whole-window, --border, --exclude-titlebar, --locked
            rest = rest.splitFirstWord().rest
        }
        let (combo, action) = rest.splitFirstWord()
        guard !action.isEmpty else {
            skip(line, original, "binding has no action")
            return
        }
        switch mapKeyCombo(combo) {
            case .failure(let reason):
                skip(line, original, reason)
            case .success(let binding):
                let (commands, subDiagnostics) = mapActionList(action)
                for reason in subDiagnostics {
                    note(line, original, reason)
                }
                if commands.isEmpty {
                    skip(line, original, "none of the actions in this binding have an equivalent")
                } else {
                    builder.bindings.append((mode: mode, key: binding, commands: commands))
                }
        }
    }

    func mapKeyCombo(_ combo: String) -> Result<String, String> {
        var alt = false, ctrl = false, cmd = false, shift = false
        var key: String? = nil
        for part in combo.split(separator: "+").map(String.init) {
            switch part.lowercased() {
                case "mod1", "alt": alt = true
                case "mod4", "super", "mod": mod4Target == "cmd" ? (cmd = true) : (alt = true)
                case "control", "ctrl": ctrl = true
                case "shift": shift = true
                case "mod2", "mod3", "mod5":
                    return .failure("modifier '\(part)' has no macOS equivalent")
                default:
                    guard let mapped = mapKeysym(part) else {
                        return .failure("key '\(part)' has no equivalent key notation")
                    }
                    key = mapped
            }
        }
        guard let key else { return .failure("no key in binding '\(combo)'") }
        var result: [String] = []
        if alt { result.append("alt") }
        if ctrl { result.append("ctrl") }
        if cmd { result.append("cmd") }
        if shift { result.append("shift") }
        result.append(key)
        return .success(result.joined(separator: "-"))
    }

    func mapKeysym(_ keysym: String) -> String? {
        let special: [String: String] = [
            "return": "enter", "kp_enter": "keypadEnter", "escape": "esc", "backspace": "backspace",
            "delete": "forwardDelete", "prior": "pageUp", "next": "pageDown", "home": "home", "end": "end",
            "left": "left", "down": "down", "up": "up", "right": "right", "space": "space", "tab": "tab",
            "minus": "minus", "equal": "equal", "plus": "equal", "comma": "comma", "period": "period",
            "slash": "slash", "backslash": "backslash", "semicolon": "semicolon", "apostrophe": "quote",
            "grave": "backtick", "bracketleft": "leftSquareBracket", "bracketright": "rightSquareBracket",
        ]
        let lower = keysym.lowercased()
        if let mapped = special[lower] { return mapped }
        if lower.count == 1, let ch = lower.first, ch.isLetter || ch.isNumber { return lower }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1 ... 20).contains(n) { return lower }
        return nil
    }

    // MARK: Actions

    /// Maps a (possibly `;`/`,`-chained) i3 action list. Returns mapped commands + reasons for dropped parts
    func mapActionList(_ action: String) -> (commands: [String], dropped: [String]) {
        var commands: [String] = []
        var dropped: [String] = []
        for part in splitActions(action) {
            switch mapAction(part) {
                case .success(let mapped): commands += mapped
                case .failure(let reason): dropped.append("'\(part)': \(reason)")
            }
        }
        return (commands, dropped)
    }

    /// exec consumes the rest of the line; everything else splits on ';' and ','
    func splitActions(_ action: String) -> [String] {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("exec") { return [trimmed] }
        return trimmed
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func mapAction(_ action: String) -> Result<[String], String> {
        let (word, rest) = action.splitFirstWord()
        let arg = rest.trimmingCharacters(in: .whitespaces)
        switch word {
            case "exec":
                let cmd = arg.removePrefixIfPresent("--no-startup-id").trimmingCharacters(in: .whitespaces)
                return .success(["exec-and-forget \(cmd)"])
            case "focus":
                switch arg {
                    case "left", "right", "up", "down": return .success(["focus \(arg)"])
                    case "next": return .success(["focus dfs-next"])
                    case "prev": return .success(["focus dfs-prev"])
                    default:
                        if arg.hasPrefix("output ") {
                            return mapMonitorTarget(String(arg.dropFirst("output ".count)), command: "focus-monitor")
                        }
                        return .failure("focus \(arg) has no equivalent")
                }
            case "move":
                return mapMoveAction(arg)
            case "workspace":
                var name = arg.removePrefixIfPresent("--no-auto-back-and-forth").trimmingCharacters(in: .whitespaces)
                name = name.removePrefixIfPresent("number").trimmingCharacters(in: .whitespaces).unquoted()
                switch name {
                    case "next", "prev": return .success(["workspace \(name)"])
                    case "next_on_output": return .success(["workspace next"])
                    case "prev_on_output": return .success(["workspace prev"])
                    case "back_and_forth": return .success(["workspace-back-and-forth"])
                    default: return .success(["workspace \(name)"])
                }
            case "split":
                switch arg {
                    case "h", "horizontal": return .success(["split horizontal"])
                    case "v", "vertical": return .success(["split vertical"])
                    case "t", "toggle": return .success(["split opposite"])
                    default: return .failure("split \(arg) has no equivalent")
                }
            case "layout":
                switch arg {
                    case "stacking", "stacked", "tabbed": return .success(["layout accordion"])
                    case "splith": return .success(["layout tiles horizontal"])
                    case "splitv": return .success(["layout tiles vertical"])
                    case "toggle split": return .success(["layout tiles horizontal vertical"])
                    case "toggle all", "toggle": return .success(["layout tiles accordion"])
                    default: return .failure("layout \(arg) has no equivalent")
                }
            case "fullscreen":
                return .success(["fullscreen"])
            case "floating":
                switch arg {
                    case "enable": return .success(["layout floating"])
                    case "disable": return .success(["layout tiling"])
                    case "toggle": return .success(["layout floating tiling"])
                    default: return .failure("floating \(arg) has no equivalent")
                }
            case "sticky":
                switch arg {
                    case "enable": return .success(["sticky on"])
                    case "disable": return .success(["sticky off"])
                    case "toggle": return .success(["sticky"])
                    default: return .failure("sticky \(arg) has no equivalent")
                }
            case "resize":
                return mapResizeAction(arg)
            case "kill":
                return .success(["close"])
            case "reload", "restart":
                return .success(["reload-config"])
            case "mode":
                let name = arg.unquoted()
                return .success(["mode \(name == "default" ? "main" : name)"])
            case "nop":
                return .success([])
            case "exit":
                return .failure("exiting the window manager is not something you bind on macOS")
            case "scratchpad":
                return .failure("no scratchpad yet; see the summon-workspace/sticky recipes in the guide")
            case "mark", "unmark":
                return .failure("window marks are not supported")
            case "border", "opacity", "title_format", "shmlog", "debuglog":
                return .failure("no equivalent")
            case "focus_follows_mouse":
                return .failure("config option, not a bindable action")
            default:
                return .failure("unrecognized action")
        }
    }

    func mapMoveAction(_ arg: String) -> Result<[String], String> {
        var arg = arg.removePrefixIfPresent("--no-auto-back-and-forth").trimmingCharacters(in: .whitespaces)
        switch arg {
            case "left", "right", "up", "down": return .success(["move \(arg)"])
            case "scratchpad": return .failure("no scratchpad yet; see the summon-workspace/sticky recipes in the guide")
            default: break
        }
        arg = arg.removePrefixIfPresent("container").trimmingCharacters(in: .whitespaces)
        arg = arg.removePrefixIfPresent("window").trimmingCharacters(in: .whitespaces)
        if arg.hasPrefix("workspace to output") {
            return mapMonitorTarget(String(arg.dropFirst("workspace to output".count)), command: "move-workspace-to-monitor")
        }
        if arg.hasPrefix("to workspace") {
            var name = String(arg.dropFirst("to workspace".count)).trimmingCharacters(in: .whitespaces)
            name = name.removePrefixIfPresent("number").trimmingCharacters(in: .whitespaces).unquoted()
            switch name {
                case "next", "prev": return .success(["move-node-to-workspace \(name)"])
                case "back_and_forth": return .failure("moving to the previous workspace is not supported")
                default: return .success(["move-node-to-workspace \(name)"])
            }
        }
        if arg.hasPrefix("to output") {
            return mapMonitorTarget(String(arg.dropFirst("to output".count)), command: "move-node-to-monitor")
        }
        if arg.hasPrefix("position") || arg.hasPrefix("absolute") {
            if arg.contains("center") { return .success(["center-window"]) }
            return .failure("absolute positioning is not supported; see center-window")
        }
        return .failure("move \(arg) has no equivalent")
    }

    func mapMonitorTarget(_ target: String, command: String) -> Result<[String], String> {
        let t = target.trimmingCharacters(in: .whitespaces).unquoted()
        switch t {
            case "left", "right", "up", "down", "next", "prev": return .success(["\(command) \(t)"])
            case "primary": return .success(["\(command) main"])
            default: return .success(["\(command) \(t)"]) // treated as a display-name regex; flagged at the directive level
        }
    }

    func mapResizeAction(_ arg: String) -> Result<[String], String> {
        let parts = arg.split(separator: " ").map(String.init)
        // resize set [width] W [px] [height] H [px]
        if parts.first == "set" {
            let numbers = parts.compactMap { Int($0) }
            switch numbers.count {
                case 2: return .success(["resize width \(numbers[0])", "resize height \(numbers[1])"])
                case 1:
                    let dimension = parts.contains("height") ? "height" : "width"
                    return .success(["resize \(dimension) \(numbers[0])"])
                default: return .failure("can't parse resize set arguments")
            }
        }
        // resize grow|shrink width|height|up|down|left|right N px [or M ppt]
        guard parts.count >= 2, parts[0] == "grow" || parts[0] == "shrink" else {
            return .failure("can't parse resize arguments")
        }
        let sign = parts[0] == "grow" ? "+" : "-"
        let dimension: String
        switch parts[1] {
            case "width", "left", "right": dimension = "width"
            case "height", "up", "down": dimension = "height"
            default: return .failure("can't parse resize dimension '\(parts[1])'")
        }
        let amount = parts.compactMap { Int($0) }.first ?? 10
        // Prefer ppt when present: i3's ppt maps to the '%' unit
        if let orIndex = parts.firstIndex(of: "or"), let ppt = parts[orIndex...].compactMap({ Int($0) }).first {
            return .success(["resize \(dimension) \(sign)\(ppt)%"])
        }
        return .success(["resize \(dimension) \(sign)\(amount)"])
    }

    // MARK: for_window / assign / workspace / gaps

    mutating func handleForWindow(_ rest: String, original: String, line: Int) {
        guard let (criteria, command) = parseCriteria(rest) else {
            skip(line, original, "can't parse criteria")
            return
        }
        let (matchers, criteriaNotes) = mapCriteria(criteria)
        for n in criteriaNotes { note(line, original, n) }
        guard !matchers.isEmpty else {
            skip(line, original, "none of the criteria can be matched on macOS")
            return
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        // floating enable (possibly chained with more) becomes a detection rule
        if trimmedCommand.hasPrefix("floating enable") {
            builder.detectionRules.append((matchers: matchers, treatAs: "float"))
            let leftover = splitActions(trimmedCommand).filter { $0 != "floating enable" }
            if !leftover.isEmpty {
                let (commands, dropped) = mapActionList(leftover.joined(separator: "; "))
                for d in dropped { note(line, original, d) }
                if !commands.isEmpty {
                    builder.windowCallbacks.append((matchers: matchers, run: commands))
                }
            }
            return
        }
        let (commands, dropped) = mapActionList(trimmedCommand)
        for d in dropped { note(line, original, d) }
        if commands.isEmpty {
            skip(line, original, "the for_window command has no equivalent")
        } else {
            builder.windowCallbacks.append((matchers: matchers, run: commands))
        }
    }

    mutating func handleAssign(_ rest: String, original: String, line: Int) {
        guard let (criteria, target) = parseCriteria(rest) else {
            skip(line, original, "can't parse criteria")
            return
        }
        let (matchers, criteriaNotes) = mapCriteria(criteria)
        for n in criteriaNotes { note(line, original, n) }
        guard !matchers.isEmpty else {
            skip(line, original, "none of the criteria can be matched on macOS")
            return
        }
        var name = target.trimmingCharacters(in: .whitespaces)
        name = name.removePrefixIfPresent("→").trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("output ") {
            skip(line, original, "assigning apps to outputs is not supported; assign to a workspace instead")
            return
        }
        name = name.removePrefixIfPresent("workspace").trimmingCharacters(in: .whitespaces)
        name = name.removePrefixIfPresent("number").trimmingCharacters(in: .whitespaces).unquoted()
        builder.windowCallbacks.append((matchers: matchers, run: ["move-node-to-workspace \(name)"]))
    }

    mutating func handleWorkspaceDirective(_ rest: String, original: String, line: Int) {
        // workspace <name> output <out1> [out2...]  |  workspace <name> gaps ...
        guard let outputRange = rest.range(of: " output ") else {
            skip(line, original, "per-workspace settings other than 'output' are not supported")
            return
        }
        let name = String(rest[..<outputRange.lowerBound]).trimmingCharacters(in: .whitespaces).unquoted()
        let outputs = String(rest[outputRange.upperBound...]).split(separator: " ").map { String($0).unquoted() }
        guard let firstOutput = outputs.first else {
            skip(line, original, "no output specified")
            return
        }
        let mapped = firstOutput == "primary" ? "main" : firstOutput
        builder.workspaceToMonitor.append((workspace: name, output: mapped))
        if mapped != "main" {
            note(line, original, "'\(firstOutput)' is a Linux connector name; macOS matches monitors by display name — replace with 'main', 'secondary', a monitor index, or a display-name regex")
        }
    }

    mutating func handleGaps(_ rest: String, original: String, line: Int) {
        let parts = rest.split(separator: " ").map(String.init)
        guard parts.count >= 2, let value = Int(parts.last!) else {
            skip(line, original, "can't parse gaps value")
            return
        }
        switch parts[0] {
            case "inner":
                builder.gapsInner["vertical"] = value
                builder.gapsInner["horizontal"] = value
            case "outer":
                for side in ["left", "bottom", "top", "right"] { builder.gapsOuter[side] = value }
            case "horizontal": builder.gapsInner["horizontal"] = value
            case "vertical": builder.gapsInner["vertical"] = value
            case "left", "bottom", "top", "right": builder.gapsOuter[parts[0]] = value
            default:
                skip(line, original, "gaps form '\(parts[0])' is not supported")
        }
    }

    // MARK: Criteria

    /// Parses `[key="value" key2=value2] rest of line`
    func parseCriteria(_ input: String) -> (criteria: [(String, String)], rest: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
        let rest = String(trimmed[trimmed.index(after: close)...])
        var criteria: [(String, String)] = []
        var scanner = Substring(inner)
        while true {
            scanner = scanner.drop(while: { $0 == " " })
            guard let eq = scanner.firstIndex(of: "=") else { break }
            let key = String(scanner[..<eq]).trimmingCharacters(in: .whitespaces)
            scanner = scanner[scanner.index(after: eq)...]
            let value: String
            if scanner.hasPrefix("\"") {
                scanner = scanner.dropFirst()
                guard let endQuote = scanner.firstIndex(of: "\"") else { return nil }
                value = String(scanner[..<endQuote])
                scanner = scanner[scanner.index(after: endQuote)...]
            } else {
                let end = scanner.firstIndex(of: " ") ?? scanner.endIndex
                value = String(scanner[..<end])
                scanner = scanner[end...]
            }
            criteria.append((key, value))
            if scanner.isEmpty { break }
        }
        return criteria.isEmpty ? nil : (criteria, rest)
    }

    func mapCriteria(_ criteria: [(String, String)]) -> (matchers: [String], notes: [String]) {
        var matchers: [String] = []
        var notes: [String] = []
        for (key, value) in criteria {
            switch key {
                case "class", "instance", "app_id": // app_id is the sway variant
                    let normalized = value.lowercased()
                        .replacingOccurrences(of: "^", with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .replacingOccurrences(of: "(?i)", with: "")
                    if let bundleId = linuxAppClassToBundleId[normalized] {
                        matchers.append("if.app-id = \(tomlString(bundleId))")
                    } else {
                        matchers.append("if.app-name-regex-substring = \(tomlString(value))")
                        notes.append("class '\(value)' has no known macOS bundle id; matching by app name instead — adjust if needed")
                    }
                case "title":
                    matchers.append("if.window-title-regex-substring = \(tomlString(value))")
                default:
                    notes.append("criterion '\(key)' can't be matched on macOS; dropped from the rule")
            }
        }
        return (matchers, notes)
    }
}

// MARK: - String helpers

extension String {
    fileprivate func splitFirstWord() -> (word: String, rest: String) {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
        return (String(trimmed[..<space]), String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    fileprivate func removePrefixIfPresent(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    fileprivate func removeSuffixIfPresent(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    fileprivate func unquoted() -> String {
        if count >= 2, hasPrefix("\""), hasSuffix("\"") { return String(dropFirst().dropLast()) }
        return self
    }
}
