import Common
import Foundation
import Network

/// `aerospace i3-msg` / `aerospace i3-socket-path` — i3-compatible client against our i3 IPC socket.
/// Does not install a binary named `i3` (opt-in shims are a later packaging choice).

func handleI3Cli(_ args: [String]) async -> Never {
    let rest = Array(args.dropFirst())
    switch args.first {
        case "i3-socket-path", "i3-get-socketpath":
            print(i3IpcSocketPath)
            exit(EXIT_CODE_ZERO)
        case "i3-msg":
            await runI3Msg(rest)
        default:
            exit(EXIT_CODE_TWO, err: "internal: handleI3Cli called with unexpected args")
    }
}

private func runI3Msg(_ args: [String]) async -> Never {
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        exit(
            EXIT_CODE_ZERO,
            out: """
                USAGE: aerospace i3-msg [-t <type>] [-q] [<message>...]
                       aerospace i3-socket-path

                Talk to AeroSpace's i3-IPC socket (\(i3IpcSocketPath)).
                Set I3SOCK for i3ipc libraries; this CLI also defaults to that path.

                Types: command (default), get_workspaces, get_outputs, get_version, subscribe

                Note: polybar/i3status/i3bar are Linux/X11 binaries and do not run on macOS.
                """,
        )
    }

    var typeName = "command"
    var quiet = false
    var messageParts: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "-t", i + 1 < args.count {
            typeName = args[i + 1]
            i += 2
            continue
        }
        if a.hasPrefix("-t") && a.count > 2 {
            typeName = String(a.dropFirst(2))
            i += 1
            continue
        }
        if a == "-q" || a == "--quiet" {
            quiet = true
            i += 1
            continue
        }
        if a == "--get-socketpath" {
            print(i3IpcSocketPath)
            exit(EXIT_CODE_ZERO)
        }
        messageParts.append(a)
        i += 1
    }

    let messageType: I3IpcMessageType = switch typeName.lowercased() {
        case "command", "run_command": .runCommand
        case "get_workspaces": .getWorkspaces
        case "get_outputs": .getOutputs
        case "get_version": .getVersion
        case "subscribe": .subscribe
        case "get_tree": .getTree
        case "get_marks": .getMarks
        case "get_bar_config": .getBarConfig
        case "get_binding_modes": .getBindingModes
        case "get_config": .getConfig
        case "send_tick": .sendTick
        case "sync": .sync
        default:
            exitT(EXIT_CODE_TWO, err: "Unknown i3-msg type: \(typeName)")
    }

    let payload: Data = if messageType == .subscribe {
        // remaining args are event names, or a JSON array string
        if messageParts.count == 1, messageParts[0].hasPrefix("[") {
            Data(messageParts[0].utf8)
        } else {
            i3JsonData(messageParts)
        }
    } else {
        Data(messageParts.joined(separator: " ").utf8)
    }

    let sock = ProcessInfo.processInfo.environment["I3SOCK"] ?? i3IpcSocketPath
    let connection = NWConnection(to: NWEndpoint.unix(path: sock), using: .tcp)
    defer { connection.cancel() }

    let ready: NWError? = await withCheckedContinuation { cont in
        let done = I3CliDone()
        connection.stateUpdateHandler = { state in
            Task {
                let err: NWError?
                switch state {
                    case .ready: err = nil
                    case .failed(let e), .waiting(let e): err = e
                    case .cancelled, .preparing, .setup: return
                    @unknown default: return
                }
                if await done.mark() { return }
                connection.stateUpdateHandler = nil
                cont.resume(returning: err)
            }
        }
        connection.start(queue: .global())
    }
    if let ready {
        exit(EXIT_CODE_TWO, err: "Can't connect to i3 IPC socket at \(sock)\n\(ready.localizedDescription)\nIs AeroSpace.app running?")
    }

    let request = i3IpcEncodeFrame(I3IpcFrame(message: messageType, payload: payload))
    let sendErr: NWError? = await withCheckedContinuation { cont in
        connection.send(content: request, completion: .contentProcessed { cont.resume(returning: $0) })
    }
    if let sendErr {
        exit(EXIT_CODE_TWO, err: sendErr.localizedDescription)
    }

    // Read one reply frame
    var buffer = Data()
    while true {
        let chunk: Result<Data, NWError> = await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    cont.resume(returning: .failure(error))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: .success(data))
                } else {
                    cont.resume(returning: .failure(NWError.posix(.ECONNRESET)))
                }
            }
        }
        switch chunk {
            case .failure(let e):
                exit(EXIT_CODE_TWO, err: e.localizedDescription)
            case .success(let data):
                buffer.append(data)
        }
        switch i3IpcDecodeFrame(from: &buffer) {
            case .failure(.truncated):
                continue
            case .failure(let e):
                exit(EXIT_CODE_TWO, err: e.description)
            case .success(let frame):
                if !quiet {
                    let text = frame.payloadString
                    if !text.isEmpty { print(text) }
                }
                if messageType == .subscribe {
                    // Stream events until disconnect
                    while true {
                        while true {
                            switch i3IpcDecodeFrame(from: &buffer) {
                                case .failure(.truncated): break
                                case .failure: exit(EXIT_CODE_TWO, err: "bad event frame")
                                case .success(let ev):
                                    print(ev.payloadString)
                                    continue
                            }
                            break
                        }
                        let more: Result<Data, NWError> = await withCheckedContinuation { cont in
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                                if let error {
                                    cont.resume(returning: .failure(error))
                                } else if let data, !data.isEmpty {
                                    cont.resume(returning: .success(data))
                                } else {
                                    cont.resume(returning: .failure(NWError.posix(.ECONNRESET)))
                                }
                            }
                        }
                        switch more {
                            case .failure: exit(EXIT_CODE_ZERO)
                            case .success(let d): buffer.append(d)
                        }
                    }
                }
                // RUN_COMMAND: exit non-zero if any success:false
                if messageType == .runCommand,
                   let arr = try? JSONSerialization.jsonObject(with: frame.payload) as? [[String: Any]],
                   arr.contains(where: { ($0["success"] as? Bool) == false })
                {
                    exit(EXIT_CODE_TWO)
                }
                exit(EXIT_CODE_ZERO)
        }
    }
}

private actor I3CliDone {
    private var done = false
    func mark() -> Bool {
        if done { return true }
        done = true
        return false
    }
}
