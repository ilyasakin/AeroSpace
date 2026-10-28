import AppKit
import Common
import Foundation

// MARK: - Live tree → i3 JSON (MainActor)

@MainActor
func i3BuildWorkspacesPayload() -> Data {
    let focusedName = focus.workspace.name
    let dtos: [I3WorkspaceDTO] = Workspace.userFacing.map { ws in
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

// MARK: - RUN_COMMAND

/// Map one i3 command to an AeroSpace command line — the SAME translation the i3 config importer
/// applies to bindings, so `i3-msg` and a binding behave identically (criteria prefix, marks,
/// scratchpad, workspace number/next, layout cycles, fullscreen enable/disable, ...).
/// Several AeroSpace commands (e.g. `resize set W H`) are joined with `;`. nil = no equivalent.
func i3MapCommandToAerospace(_ i3Command: String) -> String? {
    let trimmed = i3Command.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = trimmed.hasSuffix(";") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
    if cmd.isEmpty { return nil }
    let commands = i3ActionToAerospaceCommands(cmd)
    return commands.isEmpty ? nil : commands.joined(separator: "; ")
}

/// Same mapping, one AeroSpace command line per element (each parsed on its own: a criteria prefix
/// belongs to its own command line)
func i3MapCommandToAerospaceCommands(_ i3Command: String) -> [String] {
    let trimmed = i3Command.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = trimmed.hasSuffix(";") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
    return cmd.isEmpty ? [] : i3ActionToAerospaceCommands(cmd)
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
        let mapped = i3MapCommandToAerospaceCommands(part)
        let aero = mapped.joined(separator: "; ")
        guard !mapped.isEmpty else {
            results.append([
                "success": false,
                "error": "unsupported i3 command in Phase 1: \(part)",
            ])
            continue
        }
        let parsed: ParsedCmd<Shell<any Command>> = mapped
            .mapAllOrFailure { parseCommand($0, allowExecAndForget: true, allowEval: false) }
            .map { Shell.newCompound($0, Shell.seq) }
        switch parsed {
            case .cmd(let shell):
                // Apply the SAME gate the native socket server applies. While the server is
                // disabled (`aerospace enable off`) it refuses commands — but i3 IPC executed them
                // regardless, so any i3-compatible client (i3-msg, polybar, a status bar, an
                // editor plugin) could keep driving the WM while the user had explicitly paused it.
                guard let token: RunSessionGuard = .isServerEnabled(orIsEnableCommand: shell.singleCmdOrNil) else {
                    results.append([
                        "success": false,
                        "error": "\(aeroSpaceAppName) server is disabled and doesn't accept commands. " +
                            "You can use 'aerospace enable on' to enable the server",
                    ])
                    continue
                }
                // And run INSIDE a session. Commands are written on the assumption that a refresh
                // session surrounds them — that is what normalizes the tree and applies layout
                // afterwards. Calling `run` raw mutated the model with no pass to render it, so an
                // i3 client's `focus`/`move` could leave windows where the tree said they weren't.
                let io = CmdIoImpl(stdin: .emptyStdin)
                let outcome = await Result {
                    try await runLightSession(.i3IpcRunCommand(aero), token) {
                        await shell.run(.defaultEnv, io)
                    }
                }
                switch outcome {
                    case .success(let code) where code.rawValue == EXIT_CODE_ZERO:
                        results.append(["success": true])
                    case .success:
                        let err = io.stderr.joined(separator: "\n")
                        results.append([
                            "success": false,
                            "error": err.isEmpty ? "command failed: \(aero)" : err,
                        ])
                    case .failure(let err):
                        results.append([
                            "success": false,
                            "error": "Fail to await main thread. \(err.localizedDescription)",
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
