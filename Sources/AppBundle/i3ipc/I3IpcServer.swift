import AppKit
import Common
import Foundation
import Network

// MARK: - Subscribers

private struct I3IpcSubscriber {
    let connection: NWConnection
    var events: Set<I3IpcEventType>
}

@MainActor private var i3IpcSubscribers: [UniqueToken: I3IpcSubscriber] = [:]

// MARK: - Server

func startI3IpcServer() {
    try? FileManager.default.removeItem(atPath: i3IpcSocketPath)
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .unix(path: i3IpcSocketPath)
    let listener = Result { try NWListener(using: params) }.getOrDie()
    listener.newConnectionHandler = { connection in
        Task.startUnstructured {
            defer { connection.cancel() }
            connection.start(queue: .global())
            await i3IpcHandleConnection(connection)
        }
    }
    listener.start(queue: .global())
}

private func i3IpcHandleConnection(_ connection: NWConnection) async {
    var buffer = Data()
    /// Every SUBSCRIBE id registered for this connection (cleaned on disconnect).
    var subIds: [UniqueToken] = []

    defer {
        let ids = subIds
        Task.startUnstructured { @MainActor in
            for id in ids {
                i3IpcSubscribers.removeValue(forKey: id)
            }
        }
    }

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
            case .failure: return
            case .success(let data): buffer.append(data)
        }

        while true {
            switch i3IpcDecodeFrame(from: &buffer) {
                case .failure(.truncated):
                    break
                case .failure:
                    return
                case .success(let frame):
                    let dispatched = await i3IpcDispatchOnMain(frame, connection: connection)
                    if let newId = dispatched.subId {
                        // Replace any prior subscription on this connection to avoid double delivery.
                        if dispatched.replacedSubIds.isEmpty == false {
                            subIds.removeAll { dispatched.replacedSubIds.contains($0) }
                        }
                        subIds.append(newId)
                    }
                    // Send subscribe/command reply *before* any further events can race in.
                    if let reply = dispatched.reply {
                        let encoded = i3IpcEncodeFrame(reply)
                        let err = await withCheckedContinuation { (cont: CheckedContinuation<NWError?, Never>) in
                            connection.send(content: encoded, completion: .contentProcessed { cont.resume(returning: $0) })
                        }
                        if err != nil { return }
                    }
                    continue
            }
            break
        }
    }
}

private struct I3IpcDispatchResult: Sendable {
    var reply: I3IpcFrame?
    var subId: UniqueToken?
    var replacedSubIds: [UniqueToken] = []
}

@MainActor
private func i3IpcDispatchOnMain(_ frame: I3IpcFrame, connection: NWConnection) async -> I3IpcDispatchResult {
    let type = I3IpcMessageType(rawValue: frame.type)
    switch type {
        case .getVersion:
            return I3IpcDispatchResult(reply: I3IpcFrame(message: .getVersion, payload: i3BuildVersionPayload()))
        case .getWorkspaces:
            return I3IpcDispatchResult(reply: I3IpcFrame(message: .getWorkspaces, payload: i3BuildWorkspacesPayload()))
        case .getOutputs:
            return I3IpcDispatchResult(reply: I3IpcFrame(message: .getOutputs, payload: i3BuildOutputsPayload()))
        case .runCommand:
            let payload = await i3RunCommandPayload(frame.payloadString)
            return I3IpcDispatchResult(reply: I3IpcFrame(message: .runCommand, payload: payload))
        case .subscribe:
            let events = i3ParseSubscribePayload(frame.payloadString)
            // Drop existing subs on this connection so a second SUBSCRIBE doesn't double-fanout.
            var replaced: [UniqueToken] = []
            for (id, sub) in i3IpcSubscribers where sub.connection === connection {
                i3IpcSubscribers.removeValue(forKey: id)
                replaced.append(id)
            }
            let id = UniqueToken()
            i3IpcSubscribers[id] = I3IpcSubscriber(connection: connection, events: events)
            return I3IpcDispatchResult(
                reply: I3IpcFrame(message: .subscribe, payload: i3JsonData(["success": true])),
                subId: id,
                replacedSubIds: replaced,
            )
        case .getTree, .getMarks, .getBarConfig, .getBindingModes, .getConfig, .sendTick, .sync:
            let err: [String: Any] = [
                "success": false,
                "error": "not implemented in AeroSpace i3-ipc Phase 1",
            ]
            return I3IpcDispatchResult(reply: I3IpcFrame(type: frame.type, payload: i3JsonData(err)))
        case nil:
            let err: [String: Any] = ["success": false, "error": "unknown message type \(frame.type)"]
            return I3IpcDispatchResult(reply: I3IpcFrame(type: frame.type, payload: i3JsonData(err)))
    }
}

private func i3ParseSubscribePayload(_ payload: String) -> Set<I3IpcEventType> {
    guard let data = payload.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    else {
        return []
    }
    return Set(arr.compactMap { I3IpcEventType(eventName: $0) })
}

// MARK: - Event fan-out

/// Test-only sink recording i3 IPC event kinds in emission order (`"workspace"`, `"window"`, …).
/// Production always leaves this `nil`.
@MainActor var i3IpcTestEventOrderSink: ((String) -> Void)?

@MainActor
func i3IpcBroadcastWorkspaceEvent(change: String, currentName: String, oldName: String?) {
    i3IpcTestEventOrderSink?("workspace")
    let current = i3WorkspaceEventNode(name: currentName)
    var payload: [String: Any] = [
        "change": change,
        "current": current,
    ]
    if let oldName {
        payload["old"] = i3WorkspaceEventNode(name: oldName)
    } else {
        payload["old"] = NSNull()
    }
    i3IpcEmit(event: .workspace, payload: payload)
}

@MainActor
func i3IpcBroadcastWindowEvent(change: String, windowId: UInt32?, workspace: String) {
    i3IpcTestEventOrderSink?("window")
    let container: [String: Any]
    if let windowId {
        container = [
            "id": Int(windowId),
            "type": "con",
            "name": workspace,
            "focused": true,
            "window": Int(windowId),
        ]
    } else {
        // Empty workspace focus — no X11 window; still emit a minimal container so clients don't NPE.
        container = [
            "id": NSNull(),
            "type": "workspace",
            "name": workspace,
            "focused": true,
            "window": NSNull(),
            "nodes": [] as [Any],
        ]
    }
    let payload: [String: Any] = [
        "change": change,
        "container": container,
    ]
    i3IpcEmit(event: .window, payload: payload)
}

@MainActor
private func i3WorkspaceEventNode(name: String) -> [String: Any] {
    let ws = Workspace.get(byName: name)
    let mon = ws.workspaceMonitor
    let r = mon.rect
    return [
        "id": i3WorkspaceNum(from: name),
        "num": i3WorkspaceNum(from: name),
        "name": name,
        "type": "workspace",
        "output": mon.name,
        "focused": focus.workspace.name == name,
        "visible": ws.isVisible,
        "rect": I3RectDTO(
            x: Int(r.topLeftX.rounded()),
            y: Int(r.topLeftY.rounded()),
            width: Int(r.width.rounded()),
            height: Int(r.height.rounded()),
        ).asDict,
    ]
}

@MainActor
private func i3IpcEmit(event: I3IpcEventType, payload: [String: Any]) {
    let frame = I3IpcFrame(event: event, payload: i3JsonData(payload))
    let encoded = i3IpcEncodeFrame(frame)
    // Snapshot keys so we can remove failed connections without mutating during iteration races.
    let snapshot = i3IpcSubscribers
    for (id, sub) in snapshot {
        guard sub.events.contains(event) else { continue }
        Task.startUnstructured {
            let err = await withCheckedContinuation { (cont: CheckedContinuation<NWError?, Never>) in
                sub.connection.send(content: encoded, completion: .contentProcessed { cont.resume(returning: $0) })
            }
            if err != nil {
                await MainActor.run {
                    i3IpcSubscribers.removeValue(forKey: id)
                }
            }
        }
    }
}
