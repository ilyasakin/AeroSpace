import Common
import Foundation

/// Translates an i3 (i3wm / i3-gaps) config into a native config + compatibility diagnostics.
/// Pure: no IO except includes, which go through options.readIncludedFile
func importI3Config(_ text: String, _ options: ImportOptions = ImportOptions()) -> ImportResult {
    var ctx = I3ImportContext(options: options)
    // i3 is manual tiling; pin it explicitly since the shipped default policy is dwindle
    ctx.builder.tilingPolicy = "manual"
    // i3 defaults a config that doesn't mention them would otherwise lose
    ctx.builder.mouseWarping = "output"
    ctx.parseLines(text)
    ctx.finalizeI3Gaps()
    // i3's own tree normalization: only redundant split pairs collapse, `split` works
    ctx.builder.i3Normalization = true
    // i3 tabbed/stacked presentation: members fill the container under a title band
    ctx.builder.i3AccordionMode = true
    let toml = emitAeroToml(builder: ctx.builder, diagnostics: ctx.diagnostics, sourceKind: "i3")
    return ImportResult(toml: toml, diagnostics: ctx.diagnostics, directiveCount: ctx.directiveCount)
}

/// Quotes a command argument for the aerospace shell if it contains characters
/// that the bare-word lexer would reject (spaces, colons, quotes, ...)
func shellQuoteArg(_ arg: String) -> String {
    let bareAllowed = arg.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    if bareAllowed && !arg.isEmpty { return arg }
    if !arg.contains("'") { return "'\(arg)'" }
    return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
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
    var persistentWorkspaces: [String] = []
    var detectionRules: [(matchers: [String], treatAs: String)] = []
    var windowCallbacks: [(matchers: [String], run: [String])] = []
    var i3Normalization = false
    var i3AccordionMode = false
    var tilingPolicy: String? = nil
    /// i3 focus_wrapping (yes|no|force|workspace)
    var focusWrapping: String? = nil
    /// i3 mouse_warping (none|output|container); i3's default is output
    var mouseWarping: String? = nil
    var workspaceAutoBackAndForth = false
    var smartGaps = false
    /// Border style fragments emitted under [window-borders]
    var windowBorders: [String] = []
}

private struct I3ImportContext {
    let options: ImportOptions
    var builder = AeroConfigBuilder()
    var diagnostics: [ImportDiagnostic] = []
    var directiveCount = 0
    var variables: [String: String] = [:]
    var usesMod1 = false
    var usesMod4 = false
    var renamedWorkspaces: Set<String> = []

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
            case "focus_wrapping":
                let value = rest.trimmingCharacters(in: .whitespaces)
                switch value {
                    case "yes", "true": builder.focusWrapping = "yes"
                    case "no", "false": builder.focusWrapping = "no"
                    case "force", "workspace": builder.focusWrapping = value
                    default: skip(lineNo, original, "unknown focus_wrapping value")
                }
            case "force_focus_wrapping":
                // Deprecated i3 spelling of `focus_wrapping force`
                if ["yes", "true"].contains(rest.trimmingCharacters(in: .whitespaces)) { builder.focusWrapping = "force" }
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
            case "default_border", "new_window":
                // AeroSpace draws its own borders ([window-borders]); i3 title bars can't be drawn
                let parts = rest.split(separator: " ").map(String.init)
                switch parts.first {
                    case "pixel":
                        let width = parts.count > 1 ? Int(parts[1].removeSuffixIfPresent("px")) ?? 1 : 1
                        builder.windowBorders.removeAll { $0.hasPrefix("width = ") }
                        builder.windowBorders.append("width = \(width)")
                    case "normal":
                        let width = parts.count > 1 ? Int(parts[1].removeSuffixIfPresent("px")) ?? 2 : 2
                        builder.windowBorders.removeAll { $0.hasPrefix("width = ") }
                        builder.windowBorders.append("width = \(width)")
                        note(lineNo, original, "title bars are drawn by macOS; only the border is kept")
                    case "none":
                        builder.windowBorders.removeAll()
                    default:
                        skip(lineNo, original, "unknown border style")
                }
            case "default_floating_border", "new_float":
                skip(lineNo, original, "floating windows share the one border style")
            case "hide_edge_borders", "smart_borders":
                skip(lineNo, original, "edge/smart border hiding is not supported")
            case "smart_gaps":
                switch rest.trimmingCharacters(in: .whitespaces) {
                    case "on", "yes", "true": builder.smartGaps = true
                    case "off", "no", "false": builder.smartGaps = false
                    default: skip(lineNo, original, "only 'smart_gaps on|off' is supported")
                }
            case "mouse_warping":
                let value = rest.trimmingCharacters(in: .whitespaces)
                if ["none", "output", "container"].contains(value) { builder.mouseWarping = value }
                else { skip(lineNo, original, "unknown mouse_warping value") }
            case "workspace_auto_back_and_forth":
                builder.workspaceAutoBackAndForth = ["yes", "true"].contains(rest.trimmingCharacters(in: .whitespaces))
            case "popup_during_fullscreen", "force_display_urgency_hint", "focus_on_window_activation",
                 "show_marks", "tiling_drag", "ipc-socket", "ipc_socket", "restart_state",
                 "floating_minimum_size", "floating_maximum_size":
                skip(lineNo, original, "behavior tweak with no equivalent")
            default:
                if word == "client.focused" || word == "client.unfocused" {
                    // client.<class> <border> <background> <text> <indicator> <child_border>
                    let colors = rest.split(separator: " ").map(String.init)
                    let color = colors.count >= 5 ? colors[4] : colors.first
                    if let color, color.hasPrefix("#") {
                        let key = word == "client.focused" ? "active-color" : "inactive-color"
                        builder.windowBorders.removeAll { $0.hasPrefix(key) }
                        builder.windowBorders.append("\(key) = \(tomlString(color))")
                    } else {
                        skip(lineNo, original, "can't parse the border color")
                    }
                } else if word.hasPrefix("client.") {
                    skip(lineNo, original, "only focused/unfocused border colors are drawn")
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

    /// Strips whitespace: AeroSpace forbids whitespace in workspace names
    mutating func sanitizeWorkspace(_ name: String) -> String {
        let sanitized = name.filter { !$0.isWhitespace }
        if sanitized != name, renamedWorkspaces.insert(name).inserted {
            note(0, "workspace \"\(name)\"", "renamed to '\(sanitized)' (whitespace is forbidden in workspace names)")
        }
        return sanitized.isEmpty ? "1" : sanitized
    }

    /// Maps a (possibly `;`/`,`-chained) i3 action list. Returns mapped commands + reasons for dropped parts.
    /// i3 criteria carry across `,` and are reset by `;` (commands.c); `exec` ignores them.
    mutating func mapActionList(_ action: String) -> (commands: [String], dropped: [String]) {
        var commands: [String] = []
        var dropped: [String] = []
        var prefix: String? = nil
        for (part, afterSemicolon) in splitActions(action) {
            if afterSemicolon { prefix = nil }
            var body = part
            if let (terms, rest) = splitI3CriteriaPrefix(part) {
                prefix = "[" + terms.map(renderCriterionTerm).joined(separator: " ") + "] "
                body = rest
            }
            switch mapAction(body) {
                case .success(let mapped):
                    commands += mapped.map { m in
                        guard let prefix, !m.hasPrefix("exec-and-forget") else { return m }
                        return prefix + m
                    }
                case .failure(let reason): dropped.append("'\(part)': \(reason)")
            }
        }
        return (commands, dropped)
    }

    func renderCriterionTerm(_ term: String) -> String {
        guard let eq = term.firstIndex(of: "=") else { return term }
        return term[..<eq] + "=\"" + term[term.index(after: eq)...] + "\""
    }

    /// Splits on `;` and `,` outside quotes and brackets; `exec` consumes the rest of its part.
    /// Each element: the action and whether a `;` (not a `,`) preceded it.
    func splitActions(_ action: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var quote: Character? = nil
        var bracketDepth = 0
        var afterSemicolon = false
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { result.append((t, afterSemicolon)) }
            current = ""
        }
        for ch in action {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            let isExec = current.trimmingCharacters(in: .whitespaces).hasPrefix("exec")
                || current.trimmingCharacters(in: .whitespaces).range(of: #"^\[[^\]]*\]\s*exec"#, options: .regularExpression) != nil
            switch ch {
                case "\"", "'": quote = ch; current.append(ch)
                case "[": bracketDepth += 1; current.append(ch)
                case "]": bracketDepth = max(0, bracketDepth - 1); current.append(ch)
                case ";" where bracketDepth == 0 && !isExec, "," where bracketDepth == 0 && !isExec:
                    flush()
                    afterSemicolon = ch == ";"
                default: current.append(ch)
            }
        }
        flush()
        return result
    }

    mutating func mapAction(_ action: String) -> Result<[String], String> {
        let (rawWord, rest) = action.splitFirstWord()
        // i3 keywords are case-insensitive (strncasecmp); names/marks/titles keep their case
        let word = rawWord.lowercased()
        let arg = rest.trimmingCharacters(in: .whitespaces)
        let lowerArg = arg.lowercased()
        switch word {
            case "exec":
                let cmd = arg.removePrefixIfPresent("--no-startup-id").trimmingCharacters(in: .whitespaces)
                return .success(["exec-and-forget \(cmd)"])
            case "focus":
                switch lowerArg {
                    case "left", "right", "up", "down": return .success(["focus \(lowerArg)"])
                    case "next", "prev": return .success(["focus \(lowerArg)"])
                    case "next sibling": return .success(["focus next-sibling"])
                    case "prev sibling": return .success(["focus prev-sibling"])
                    case "parent", "child", "floating", "tiling": return .success(["focus \(lowerArg)"])
                    case "mode_toggle": return .success(["focus mode-toggle"])
                    case "": return .success(["focus"]) // with a criteria prefix: focus the match
                    default:
                        if arg.hasPrefix("output ") {
                            return mapMonitorTarget(String(arg.dropFirst("output ".count)), command: "focus-monitor")
                        }
                        return .failure("focus \(arg) has no equivalent")
                }
            case "move":
                return mapMoveAction(arg)
            case "workspace":
                let noAuto = arg.hasPrefix("--no-auto-back-and-forth")
                var name = arg.removePrefixIfPresent("--no-auto-back-and-forth").trimmingCharacters(in: .whitespaces)
                let isNumber = name.hasPrefix("number")
                name = name.removePrefixIfPresent("number").trimmingCharacters(in: .whitespaces).unquoted()
                switch name {
                    // i3 `next`/`prev` span every output and wrap; `*_on_output` stay on this one
                    case "next", "prev": return .success(["workspace --all-monitors --wrap-around \(name)"])
                    case "next_on_output": return .success(["workspace --wrap-around next"])
                    case "prev_on_output": return .success(["workspace --wrap-around prev"])
                    case "back_and_forth": return .success(["workspace-back-and-forth"])
                    default:
                        let ws = shellQuoteArg(sanitizeWorkspace(name))
                        let flags = (noAuto ? "--no-auto-back-and-forth " : "") + (isNumber && name.first?.isNumber == true ? "--number " : "")
                        return .success(["workspace \(flags)\(ws)"])
                }
            case "split":
                switch lowerArg {
                    case "h", "horizontal": return .success(["split horizontal"])
                    case "v", "vertical": return .success(["split vertical"])
                    case "t", "toggle": return .success(["split opposite"])
                    default: return .failure("split \(arg) has no equivalent")
                }
            case "layout":
                let arg = lowerArg
                switch arg {
                    // tabbed = a horizontal accordion, stacking = a vertical one (focus direction matches)
                    case "tabbed": return .success(["layout h_accordion"])
                    case "stacking", "stacked": return .success(["layout v_accordion"])
                    case "splith": return .success(["layout h_tiles"])
                    case "splitv": return .success(["layout v_tiles"])
                    case "default": return .success(["layout tiles"])
                    case "toggle split": return .success(["layout h_tiles v_tiles"])
                    // i3 cycles stacked → tabbed → splith → splitv
                    case "toggle all", "toggle": return .success(["layout v_accordion h_accordion h_tiles v_tiles"])
                    default:
                        if arg.hasPrefix("toggle ") {
                            let names: [String: String] = ["split": "h_tiles v_tiles", "splith": "h_tiles", "splitv": "v_tiles", "tabbed": "h_accordion", "stacking": "v_accordion", "stacked": "v_accordion"]
                            let parts = arg.dropFirst("toggle ".count).split(separator: " ").map { names[String($0)] }
                            if parts.allSatisfy({ $0 != nil }) { return .success(["layout " + parts.compactMap(\.self).joined(separator: " ")]) }
                        }
                        return .failure("layout \(arg) has no equivalent")
                }
            case "fullscreen":
                // `fullscreen disable` used to TOGGLE (turning fullscreen on); global maps to per-workspace
                let mode = lowerArg.split(separator: " ").first.map(String.init) ?? "toggle"
                switch mode {
                    case "enable": return .success(["fullscreen on"])
                    case "disable": return .success(["fullscreen off"])
                    default: return .success(["fullscreen"])
                }
            case "floating":
                switch lowerArg {
                    case "enable": return .success(["layout floating"])
                    case "disable": return .success(["layout tiling"])
                    case "toggle": return .success(["layout floating tiling"])
                    default: return .failure("floating \(arg) has no equivalent")
                }
            case "sticky":
                switch lowerArg {
                    case "enable": return .success(["sticky on"])
                    case "disable": return .success(["sticky off"])
                    case "toggle": return .success(["sticky"])
                    default: return .failure("sticky \(arg) has no equivalent")
                }
            case "resize":
                return mapResizeAction(arg)
            case "kill":
                return .success(["close"])
            case "rename":
                // i3: rename workspace [<old>] to <new>
                let body = arg.removePrefixIfPresent("workspace").trimmingCharacters(in: .whitespaces)
                // `to <new>` (focused workspace) or `<old> to <new>` — the FIRST " to " separates
                let (oldPart, newPart): (Substring, Substring)
                if body.hasPrefix("to ") {
                    (oldPart, newPart) = ("", body.dropFirst(3))
                } else if let r = body.range(of: " to ") {
                    (oldPart, newPart) = (body[..<r.lowerBound], body[r.upperBound...])
                } else {
                    return .failure("rename \(arg) has no equivalent")
                }
                let old = oldPart.trimmingCharacters(in: .whitespaces).unquoted()
                let new = shellQuoteArg(sanitizeWorkspace(newPart.trimmingCharacters(in: .whitespaces).unquoted()))
                return .success([old.isEmpty ? "rename-workspace \(new)" : "rename-workspace --workspace \(shellQuoteArg(sanitizeWorkspace(old))) \(new)"])
            case "gaps":
                // Same grammar natively: gaps <type> current|all set|plus|minus|toggle <px>
                let parts = arg.split(separator: " ")
                return parts.count == 4 ? .success(["gaps " + arg]) : .failure("gaps \(arg) has no equivalent")
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
                return arg == "show" ? .success(["scratchpad show"]) : .failure("scratchpad \(arg) has no equivalent")
            case "mark":
                let words = arg.split(separator: " ").map(String.init)
                let flags = words.filter { ["--add", "--replace", "--toggle"].contains($0) }
                let name = words.filter { !flags.contains($0) }.joined(separator: " ").unquoted()
                if name.isEmpty { return .failure("mark without a name") }
                return .success(["mark " + (flags + [shellQuoteArg(name)]).joined(separator: " ")])
            case "unmark":
                let name = arg.unquoted()
                return .success([name.isEmpty ? "unmark" : "unmark \(shellQuoteArg(name))"])
            case "swap":
                // i3: swap container with mark|con_id <x>
                let parts = arg.removePrefixIfPresent("container").trimmingCharacters(in: .whitespaces)
                    .removePrefixIfPresent("with").trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return .failure("swap \(arg) has no equivalent") }
                switch parts[0] {
                    case "mark": return .success(["swap --with-mark \(shellQuoteArg(parts[1].unquoted()))"])
                    default: return .failure("swap with \(parts[0]) has no equivalent")
                }
            case "border", "opacity", "title_format", "shmlog", "debuglog":
                return .failure("no equivalent")
            case "focus_follows_mouse":
                return .failure("config option, not a bindable action")
            default:
                return .failure("unrecognized action")
        }
    }

    mutating func mapMoveAction(_ arg: String) -> Result<[String], String> {
        var arg = arg.removePrefixIfPresent("--no-auto-back-and-forth").trimmingCharacters(in: .whitespaces)
        switch arg.lowercased() {
            case "left", "right", "up", "down": return .success(["move \(arg.lowercased())"])
            case "scratchpad": return .success(["scratchpad move"])
            default: break
        }
        // `move left 20 px` / `move left 20 px or 5 ppt` (floating)
        let moveParts = arg.split(separator: " ").map(String.init)
        if let dir = moveParts.first, ["left", "right", "up", "down"].contains(dir), moveParts.count >= 2,
           let px = Int(moveParts[1].removeSuffixIfPresent("px"))
        {
            return .success(["move \(dir) \(px)"])
        }
        arg = arg.removePrefixIfPresent("container").trimmingCharacters(in: .whitespaces)
        arg = arg.removePrefixIfPresent("window").trimmingCharacters(in: .whitespaces)
        if arg.hasPrefix("workspace to output") {
            return mapMonitorTarget(String(arg.dropFirst("workspace to output".count)), command: "move-workspace-to-monitor")
        }
        // i3 grammar: `move [window|container] [to] workspace|output|mark ...` — `to` is optional
        if !arg.hasPrefix("to "), ["workspace ", "output ", "mark "].contains(where: { arg.hasPrefix($0) }) {
            arg = "to " + arg
        }
        if arg.hasPrefix("to workspace") {
            var name = String(arg.dropFirst("to workspace".count)).trimmingCharacters(in: .whitespaces)
            let isNumber = name.hasPrefix("number")
            name = name.removePrefixIfPresent("number").trimmingCharacters(in: .whitespaces).unquoted()
            if isNumber, name.first?.isNumber == true {
                return .success(["move-node-to-workspace --number \(shellQuoteArg(sanitizeWorkspace(name)))"])
            }
            switch name {
                case "next", "prev": return .success(["move-node-to-workspace --wrap-around \(name)"])
                case "next_on_output": return .success(["move-node-to-workspace --wrap-around next"])
                case "prev_on_output": return .success(["move-node-to-workspace --wrap-around prev"])
                case "back_and_forth": return .success(["move-node-to-workspace back-and-forth"])
                default: return .success(["move-node-to-workspace \(shellQuoteArg(sanitizeWorkspace(name)))"])
            }
        }
        if arg.hasPrefix("to mark") {
            return .success(["move-node-to-mark \(shellQuoteArg(String(arg.dropFirst("to mark".count)).trimmingCharacters(in: .whitespaces).unquoted()))"])
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
            case "width", "height": dimension = parts[1]
            // i3 `resize grow left`: that edge moves, trading space with the one neighbour there
            case "left", "right", "up", "down": dimension = parts[1]
            default: return .failure("can't parse resize dimension '\(parts[1])'")
        }
        let amount = parts.compactMap { Int($0.removeSuffixIfPresent("px")) }.first ?? 10
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
            let leftover = splitActions(trimmedCommand).map(\.0).filter { $0 != "floating enable" }
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
        builder.windowCallbacks.append((matchers: matchers, run: ["move-node-to-workspace \(shellQuoteArg(sanitizeWorkspace(name)))"]))
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
        builder.workspaceToMonitor.append((workspace: sanitizeWorkspace(name), output: mapped))
        if mapped != "main" {
            note(line, original, "'\(firstOutput)' is a Linux connector name; macOS matches monitors by display name — replace with 'main', 'secondary', a monitor index, or a display-name regex")
        }
    }

    /// i3 4.22 gaps. `horizontal`/`vertical` are OUTER gaps (left+right / top+bottom), and i3's
    /// effective gap at a screen edge is outer + inner — here the outer gap is the absolute
    /// distance to the edge, so the inner gap is added in `finalizeI3Gaps`. `10px` is accepted.
    mutating func handleGaps(_ rest: String, original: String, line: Int) {
        let parts = rest.split(separator: " ").map(String.init)
        guard parts.count >= 2, let value = Int(parts.last!.removeSuffixIfPresent("px")) else {
            skip(line, original, "can't parse gaps value")
            return
        }
        switch parts[0] {
            case "inner":
                builder.gapsInner["vertical"] = value
                builder.gapsInner["horizontal"] = value
            case "outer":
                for side in ["left", "bottom", "top", "right"] { builder.gapsOuter[side] = value }
            case "horizontal": for side in ["left", "right"] { builder.gapsOuter[side] = value }
            case "vertical": for side in ["top", "bottom"] { builder.gapsOuter[side] = value }
            case "left", "bottom", "top", "right": builder.gapsOuter[parts[0]] = value
            default:
                skip(line, original, "gaps form '\(parts[0])' is not supported")
        }
    }

    /// Outer = i3 outer + i3 inner at every edge (see handleGaps)
    mutating func finalizeI3Gaps() {
        let inner = builder.gapsInner["horizontal"] ?? builder.gapsInner["vertical"] ?? 0
        guard inner > 0 || !builder.gapsOuter.isEmpty else { return }
        for side in ["left", "bottom", "top", "right"] {
            builder.gapsOuter[side] = (builder.gapsOuter[side] ?? 0) + inner
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

/// One i3 command → AeroSpace command lines (empty = no equivalent). Shared by the importer and the
/// i3 IPC RUN_COMMAND handler.
func i3ActionToAerospaceCommands(_ action: String) -> [String] {
    var ctx = I3ImportContext(options: ImportOptions())
    return ctx.mapActionList(action).commands
}
