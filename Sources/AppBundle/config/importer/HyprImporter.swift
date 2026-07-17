import Foundation

/// Translates a Hyprland config into a native config + compatibility diagnostics.
/// Reuses the same builder/emitter/diagnostics skeleton as the i3 importer
func importHyprConfig(_ text: String, _ options: ImportOptions = ImportOptions()) -> ImportResult {
    var ctx = HyprImportContext(options: options)
    ctx.parse(text)
    let toml = emitAeroToml(builder: ctx.builder, diagnostics: ctx.diagnostics, sourceKind: "hyprland")
    return ImportResult(toml: toml, diagnostics: ctx.diagnostics, directiveCount: ctx.directiveCount)
}

private struct HyprImportContext {
    let options: ImportOptions
    var builder = AeroConfigBuilder()
    var diagnostics: [ImportDiagnostic] = []
    var directiveCount = 0
    var variables: [String: String] = [:]
    /// Sections whose contents are swallowed with a single diagnostic
    static let swallowedSections: Set<String> = [
        "decoration", "animations", "input", "gestures", "misc", "dwindle", "master",
        "binds", "xwayland", "opengl", "render", "cursor", "debug", "device", "monitor",
        "touchpad", "touchdevice", "tablet", "ecosystem", "experimental",
    ]

    mutating func skip(_ line: Int, _ original: String, _ reason: String) {
        diagnostics.append(ImportDiagnostic(severity: .skipped, lineNumber: line, original: original, reason: reason))
    }

    mutating func note(_ line: Int, _ original: String, _ reason: String) {
        diagnostics.append(ImportDiagnostic(severity: .note, lineNumber: line, original: original, reason: reason))
    }

    mutating func parse(_ text: String) {
        var sectionStack: [String] = []
        var swallowDepth = 0 // >0 while inside a swallowed section
        var submap = "main"

        for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = i + 1
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Section handling: 'name {' opens, '}' closes
            if trimmed.hasSuffix("{") {
                let name = trimmed.dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                sectionStack.append(name)
                if swallowDepth > 0 {
                    swallowDepth += 1
                } else if Self.swallowedSections.contains(name) {
                    swallowDepth = 1
                    directiveCount += 1
                    skip(lineNo, "\(name) { ... }", "\(reasonForSection(name))")
                }
                continue
            }
            if trimmed == "}" {
                if !sectionStack.isEmpty { sectionStack.removeLast() }
                if swallowDepth > 0 { swallowDepth -= 1 }
                continue
            }
            if swallowDepth > 0 { continue }

            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = expandVariables(String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces))

            if key.hasPrefix("$") {
                variables[key] = value
                continue
            }

            directiveCount += 1
            handleAssignment(key: key.lowercased(), value: value, section: sectionStack.last ?? "", submap: &submap, line: lineNo, original: trimmed)
        }
    }

    func expandVariables(_ input: String) -> String {
        var result = input
        for (name, value) in variables.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: name, with: value)
        }
        return result
    }

    func reasonForSection(_ name: String) -> String {
        switch name {
            case "decoration", "animations": "visual effects (blur, rounding, animations) don't exist on macOS"
            case "input", "gestures", "device", "touchpad": "input devices are configured in macOS System Settings"
            case "dwindle", "master": "Hyprland layout algorithms don't apply; see default-root-container-layout"
            default: "section has no macOS equivalent"
        }
    }

    mutating func handleAssignment(key: String, value: String, section: String, submap: inout String, line: Int, original: String) {
        switch key {
            case "bind", "binde", "bindl", "bindr", "bindel", "bindle", "bindn", "bindt":
                handleBind(value, submap: submap, line: line, original: original)
            case "bindm":
                skip(line, original, "mouse bindings are not supported; windows are dragged natively on macOS")
            case "submap":
                submap = value == "reset" ? "main" : value
                if submap != "main", !builder.modeNames.contains(submap) { builder.modeNames.append(submap) }
                directiveCount -= 1
            case "exec-once", "exec":
                builder.startupCommands.append("exec-and-forget \(value)")
            case "windowrulev2", "windowrule":
                handleWindowRule(value, isV2: key == "windowrulev2", line: line, original: original)
            case "workspace":
                // workspace = 1, monitor:DP-1 [, default:true ...]
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = parts.first, let monitorPart = parts.first(where: { $0.hasPrefix("monitor:") }) {
                    let monitor = String(monitorPart.dropFirst("monitor:".count))
                    builder.workspaceToMonitor.append((workspace: name, output: monitor))
                    note(line, original, "'\(monitor)' is a compositor connector name; macOS matches monitors by display name — replace with 'main', 'secondary', a monitor index, or a display-name regex")
                } else {
                    skip(line, original, "workspace rules other than monitor assignment are not supported")
                }
            case "gaps_in" where section == "general":
                if let v = Int(value.split(separator: ",").first.map(String.init) ?? value) {
                    builder.gapsInner["vertical"] = v
                    builder.gapsInner["horizontal"] = v
                }
            case "gaps_out" where section == "general":
                if let v = Int(value.split(separator: ",").first.map(String.init) ?? value) {
                    for side in ["left", "bottom", "top", "right"] { builder.gapsOuter[side] = v }
                }
            case "layout" where section == "general":
                directiveCount -= 1 // covered by the dwindle/master section diagnostics
            case "monitor":
                skip(line, original, "monitor layout is configured in macOS System Settings")
            case "env", "envd":
                skip(line, original, "environment variables: use the [exec.env-vars] config section if needed")
            case "source":
                skip(line, original, "sourced files are not followed; import them separately if needed")
            case "layerrule", "blurls", "windowrulev1":
                skip(line, original, "no macOS equivalent")
            default:
                if section == "general" {
                    skip(line, original, "general option has no macOS equivalent")
                } else {
                    skip(line, original, "unrecognized option")
                }
        }
    }

    // MARK: binds

    mutating func handleBind(_ value: String, submap: String, line: Int, original: String) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else {
            skip(line, original, "can't parse bind (expected MODS, key, dispatcher[, args])")
            return
        }
        let mods = parts[0]
        let key = parts[1]
        let dispatcher = parts[2].lowercased()
        let arg = parts.count > 3 ? parts[3...].joined(separator: ",").trimmingCharacters(in: .whitespaces) : ""

        guard let binding = mapBind(mods: mods, key: key) else {
            skip(line, original, "key '\(key)' or modifiers '\(mods)' have no equivalent")
            return
        }
        switch mapDispatcher(dispatcher, arg: arg) {
            case .failure(let reason):
                skip(line, original, reason)
            case .success(let commands) where commands.isEmpty:
                directiveCount -= 1
            case .success(let commands):
                builder.bindings.append((mode: submap, key: binding, commands: commands))
        }
    }

    func mapBind(mods: String, key: String) -> String? {
        var alt = false, ctrl = false, cmd = false, shift = false
        let modTokens = mods.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "+" }).map { String($0).lowercased() }
        for token in modTokens {
            switch token {
                case "super", "mod4", "win": options.mod4Target == "cmd" ? (cmd = true) : (alt = true)
                case "alt", "mod1": alt = true
                case "ctrl", "control": ctrl = true
                case "shift": shift = true
                case "": break
                default: return nil
            }
        }
        let keyMap: [String: String] = [
            "return": "enter", "escape": "esc", "space": "space", "tab": "tab", "backspace": "backspace",
            "delete": "forwardDelete", "left": "left", "right": "right", "up": "up", "down": "down",
            "minus": "minus", "equal": "equal", "grave": "backtick", "comma": "comma", "period": "period",
            "slash": "slash", "semicolon": "semicolon", "apostrophe": "quote",
            "bracketleft": "leftSquareBracket", "bracketright": "rightSquareBracket", "backslash": "backslash",
            "prior": "pageUp", "next": "pageDown", "home": "home", "end": "end",
        ]
        let lower = key.lowercased()
        let mappedKey: String
        if let m = keyMap[lower] {
            mappedKey = m
        } else if lower.count == 1, let ch = lower.first, ch.isLetter || ch.isNumber {
            mappedKey = lower
        } else if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1 ... 20).contains(n) {
            mappedKey = lower
        } else {
            return nil
        }
        var result: [String] = []
        if alt { result.append("alt") }
        if ctrl { result.append("ctrl") }
        if cmd { result.append("cmd") }
        if shift { result.append("shift") }
        result.append(mappedKey)
        return result.joined(separator: "-")
    }

    mutating func mapDispatcher(_ dispatcher: String, arg: String) -> Result<[String], String> {
        switch dispatcher {
            case "exec": return .success(["exec-and-forget \(arg)"])
            case "killactive": return .success(["close"])
            case "togglefloating": return .success(["layout floating tiling"])
            case "fullscreen", "fullscreenstate": return .success(["fullscreen"])
            case "pin": return .success(["sticky"])
            case "centerwindow": return .success(["center-window"])
            case "togglesplit": return .success(["split opposite"])
            case "workspace":
                switch arg {
                    case "e+1", "m+1", "+1": return .success(["workspace next"])
                    case "e-1", "m-1", "-1": return .success(["workspace prev"])
                    case "previous": return .success(["workspace-back-and-forth"])
                    default:
                        if arg.hasPrefix("special") { return .failure("special workspaces are not supported; see the sticky command") }
                        return .success(["workspace \(shellQuoteArg(sanitizeWorkspace(arg)))"])
                }
            case "movetoworkspace", "movetoworkspacesilent":
                if arg.hasPrefix("special") { return .failure("special workspaces are not supported; see the sticky command") }
                return .success(["move-node-to-workspace \(shellQuoteArg(sanitizeWorkspace(arg)))"])
            case "togglespecialworkspace":
                return .failure("special workspaces are not supported; see the sticky command")
            case "movefocus":
                guard let direction = mapDirection(arg) else { return .failure("can't parse direction '\(arg)'") }
                return .success(["focus \(direction)"])
            case "movewindow", "swapwindow":
                guard let direction = mapDirection(arg) else { return .failure("can't parse direction '\(arg)'") }
                return .success(["move \(direction)"])
            case "focusmonitor":
                guard let direction = mapDirection(arg) else { return .failure("can't parse direction '\(arg)'") }
                return .success(["focus-monitor \(direction)"])
            case "movecurrentworkspacetomonitor":
                guard let direction = mapDirection(arg) else { return .failure("can't parse direction '\(arg)'") }
                return .success(["move-workspace-to-monitor \(direction)"])
            case "resizeactive":
                let numbers = arg.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
                guard numbers.count == 2 else { return .failure("can't parse resizeactive arguments") }
                var commands: [String] = []
                if numbers[0] != 0 { commands.append("resize width \(numbers[0] > 0 ? "+" : "-")\(abs(numbers[0]))") }
                if numbers[1] != 0 { commands.append("resize height \(numbers[1] > 0 ? "+" : "-")\(abs(numbers[1]))") }
                return .success(commands)
            case "submap":
                return .success(["mode \(arg == "reset" ? "main" : arg)"])
            case "cyclenext": return .success(["focus dfs-next"])
            case "exit": return .failure("exiting the window manager is not something you bind on macOS")
            case "splitratio": return .failure("split ratios are not supported; see the resize command")
            case "pseudo": return .failure("pseudo-tiling has no equivalent")
            case "movecursortocorner", "movecursor": return .failure("cursor positioning is not supported")
            case "forcerendererreload", "dpms": return .failure("compositor-specific")
            default: return .failure("dispatcher '\(dispatcher)' has no equivalent")
        }
    }

    func mapDirection(_ arg: String) -> String? {
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

    mutating func sanitizeWorkspace(_ name: String) -> String {
        var name = name
        if name.hasPrefix("name:") { name = String(name.dropFirst("name:".count)) }
        let sanitized = name.filter { !$0.isWhitespace }
        return sanitized.isEmpty ? "1" : sanitized
    }

    // MARK: window rules

    mutating func handleWindowRule(_ value: String, isV2: Bool, line: Int, original: String) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else {
            skip(line, original, "can't parse window rule")
            return
        }
        let action = parts[0].lowercased()
        var matchers: [String] = []
        var matcherNotes: [String] = []
        if isV2 {
            for criterion in parts[1...] {
                guard let colon = criterion.firstIndex(of: ":") else { continue }
                let kind = String(criterion[..<colon])
                let pattern = String(criterion[criterion.index(after: colon)...])
                switch kind {
                    case "class", "initialclass":
                        appendClassMatcher(pattern, to: &matchers, notes: &matcherNotes)
                    case "title", "initialtitle":
                        matchers.append("if.window-title-regex-substring = \(tomlString(pattern))")
                    default:
                        matcherNotes.append("criterion '\(kind)' can't be matched on macOS; dropped from the rule")
                }
            }
        } else {
            appendClassMatcher(parts[1], to: &matchers, notes: &matcherNotes)
        }
        for n in matcherNotes { note(line, original, n) }
        guard !matchers.isEmpty else {
            skip(line, original, "none of the criteria can be matched on macOS")
            return
        }

        switch action {
            case "float": builder.detectionRules.append((matchers: matchers, treatAs: "float"))
            case "tile": builder.detectionRules.append((matchers: matchers, treatAs: "tile"))
            case "pin": builder.windowCallbacks.append((matchers: matchers, run: ["layout floating", "sticky on"]))
            case "fullscreen": builder.windowCallbacks.append((matchers: matchers, run: ["fullscreen"]))
            case "center": builder.windowCallbacks.append((matchers: matchers, run: ["center-window"]))
            default:
                if action.hasPrefix("workspace") {
                    var target = String(action.dropFirst("workspace".count)).trimmingCharacters(in: .whitespaces)
                    if target.isEmpty, parts.count >= 3 { target = parts[1] } // 'workspace, 3, class:...' form
                    target = target.replacingOccurrences(of: "silent", with: "").trimmingCharacters(in: .whitespaces)
                    builder.windowCallbacks.append((matchers: matchers, run: ["move-node-to-workspace \(shellQuoteArg(sanitizeWorkspace(target)))"]))
                } else {
                    skip(line, original, "window rule action '\(action)' has no equivalent (visual effects don't exist on macOS)")
                }
        }
    }

    mutating func appendClassMatcher(_ pattern: String, to matchers: inout [String], notes: inout [String]) {
        let normalized = pattern.lowercased()
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if let bundleId = linuxAppClassToBundleId[normalized] {
            matchers.append("if.app-id = \(tomlString(bundleId))")
        } else {
            matchers.append("if.app-name-regex-substring = \(tomlString(pattern))")
            notes.append("class '\(pattern)' has no known macOS bundle id; matching by app name instead — adjust if needed")
        }
    }
}
