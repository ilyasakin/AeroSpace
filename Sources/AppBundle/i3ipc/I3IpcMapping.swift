import AppKit
import Common
import Foundation

// MARK: - Live tree → i3 JSON (MainActor)

@MainActor
func i3BuildWorkspacesPayload() -> Data {
    let focusedName = focus.workspace.name
    let dtos: [I3WorkspaceDTO] = Workspace.all.map { ws in
        let mon = ws.workspaceMonitor
        let r = mon.rect
        return I3WorkspaceDTO(
            num: i3WorkspaceNum(from: ws.name),
            name: ws.name,
            visible: ws.isVisible,
            focused: ws.name == focusedName,
            urgent: false, // macOS has no i3 urgency hint yet
            output: mon.name,
            rect: I3RectDTO(
                x: Int(r.topLeftX.rounded()),
                y: Int(r.topLeftY.rounded()),
                width: Int(r.width.rounded()),
                height: Int(r.height.rounded()),
            ),
        )
    }
    return i3JsonData(dtos.map(\.asDict))
}

@MainActor
func i3BuildOutputsPayload() -> Data {
    let primaryName = mainMonitor.name
    let dtos: [I3OutputDTO] = monitors.map { mon in
        let r = mon.rect
        return I3OutputDTO(
            name: mon.name,
            active: true,
            primary: mon.name == primaryName,
            rect: I3RectDTO(
                x: Int(r.topLeftX.rounded()),
                y: Int(r.topLeftY.rounded()),
                width: Int(r.width.rounded()),
                height: Int(r.height.rounded()),
            ),
            currentWorkspace: mon.activeWorkspace.name,
        )
    }
    return i3JsonData(dtos.map(\.asDict))
}

@MainActor
func i3BuildVersionPayload() -> Data {
    i3JsonData(i3IpcVersionPayload(productVersion: aeroSpaceAppVersion))
}

// MARK: - RUN_COMMAND (Phase 1: common verbs, no [criteria])

/// Map a single i3 command string to AeroSpace CLI args (space-separated tokens as one command line).
/// Returns nil when the verb is unsupported in Phase 1.
func i3MapCommandToAerospace(_ i3Command: String) -> String? {
    let trimmed = i3Command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // Strip trailing `;` used in i3 command chains (caller splits chains)
    let cmd = trimmed.hasSuffix(";") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
    let lower = cmd.lowercased()

    // workspace …
    if lower == "workspace back_and_forth" || lower == "workspace back-and-forth" {
        return "workspace-back-and-forth"
    }
    if lower.hasPrefix("workspace number ") {
        let rest = String(cmd.dropFirst("workspace number ".count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : "workspace \(rest)"
    }
    if lower.hasPrefix("workspace ") {
        let rest = String(cmd.dropFirst("workspace ".count)).trimmingCharacters(in: .whitespaces)
        // next/prev → next/prev (AeroSpace supports these on workspace)
        if rest.lowercased() == "next" { return "workspace next" }
        if rest.lowercased() == "prev" || rest.lowercased() == "previous" { return "workspace prev" }
        return rest.isEmpty ? nil : "workspace \(rest)"
    }

    // focus …
    if lower.hasPrefix("focus ") {
        let rest = String(cmd.dropFirst("focus ".count)).trimmingCharacters(in: .whitespaces).lowercased()
        switch rest {
            case "left", "right", "up", "down": return "focus \(rest)"
            case "parent": return "focus parent" // may fail if not supported — still map
            case "child": return "focus child"
            case "floating", "tiling", "mode_toggle": return nil // Phase 2
            default: return "focus \(rest)"
        }
    }

    // move …
    if lower.hasPrefix("move ") {
        let rest = String(cmd.dropFirst("move ".count)).trimmingCharacters(in: .whitespaces)
        let restLower = rest.lowercased()
        if ["left", "right", "up", "down"].contains(restLower) {
            return "move \(restLower)"
        }
        if restLower.hasPrefix("workspace number ") {
            let name = String(rest.dropFirst("workspace number ".count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : "move-node-to-workspace \(name)"
        }
        if restLower.hasPrefix("workspace ") {
            let name = String(rest.dropFirst("workspace ".count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : "move-node-to-workspace \(name)"
        }
        if restLower.hasPrefix("container to workspace ") {
            let name = String(rest.dropFirst("container to workspace ".count)).trimmingCharacters(in: .whitespaces)
            let cleaned = name.lowercased().hasPrefix("number ")
                ? String(name.dropFirst("number ".count)).trimmingCharacters(in: .whitespaces)
                : name
            return cleaned.isEmpty ? nil : "move-node-to-workspace \(cleaned)"
        }
        return nil
    }

    // layout …
    if lower.hasPrefix("layout ") {
        let rest = String(cmd.dropFirst("layout ".count)).trimmingCharacters(in: .whitespaces).lowercased()
        switch rest {
            case "splith", "default": return "layout tiles horizontal"
            case "splitv": return "layout tiles vertical"
            case "tabbed", "stacking", "stacked": return "layout accordion"
            case "toggle split": return "layout tiles" // best-effort
            default: return nil
        }
    }

    // fullscreen [enable|disable|toggle]
    if lower == "fullscreen" || lower.hasPrefix("fullscreen ") {
        return "fullscreen"
    }

    // kill
    if lower == "kill" {
        return "close"
    }

    // floating toggle
    if lower == "floating toggle" {
        return "layout floating tiling" // or flatten — best-effort Phase 1
    }

    // reload
    if lower == "reload" {
        return "reload-config"
    }

    // exec …
    if lower.hasPrefix("exec ") {
        let rest = String(cmd.dropFirst("exec ".count)).trimmingCharacters(in: .whitespaces)
        // strip --no-startup-id
        let cleaned = rest.hasPrefix("--no-startup-id ")
            ? String(rest.dropFirst("--no-startup-id ".count))
            : rest
        return cleaned.isEmpty ? nil : "exec-and-forget \(cleaned)"
    }

    return nil
}

/// Split i3 command chains on `;` outside of single/double quotes.
func i3SplitCommandChain(_ payload: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var escape = false
    for ch in payload {
        if escape {
            current.append(ch)
            escape = false
            continue
        }
        if ch == "\\" && (inSingle || inDouble) {
            current.append(ch)
            escape = true
            continue
        }
        if ch == "'", !inDouble {
            inSingle.toggle()
            current.append(ch)
            continue
        }
        if ch == "\"", !inSingle {
            inDouble.toggle()
            current.append(ch)
            continue
        }
        if ch == ";", !inSingle, !inDouble {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current = ""
            continue
        }
        current.append(ch)
    }
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { parts.append(trimmed) }
    return parts
}

@MainActor
func i3RunCommandPayload(_ payload: String) async -> Data {
    let parts = i3SplitCommandChain(payload)
    if parts.isEmpty {
        return i3JsonData([["success": false, "error": "empty command"] as [String: Any]])
    }
    var results: [[String: Any]] = []
    for part in parts {
        guard let aero = i3MapCommandToAerospace(part) else {
            results.append([
                "success": false,
                "error": "unsupported i3 command in Phase 1: \(part)",
            ])
            continue
        }
        let parsed = parseCommand(aero, allowExecAndForget: true, allowEval: false)
        switch parsed {
            case .cmd(let shell):
                let io = CmdIoImpl(stdin: .emptyStdin)
                let code = await shell.run(.defaultEnv, io)
                if code.rawValue == EXIT_CODE_ZERO {
                    results.append(["success": true])
                } else {
                    let err = io.stderr.joined(separator: "\n")
                    results.append([
                        "success": false,
                        "error": err.isEmpty ? "command failed: \(aero)" : err,
                    ])
                }
            case .help:
                results.append(["success": true])
            case .failure(let err):
                results.append(["success": false, "error": err.msg])
        }
    }
    return i3JsonData(results)
}
