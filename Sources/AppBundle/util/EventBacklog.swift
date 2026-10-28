import Foundation
import Network

/// Bounded fan-out for subscription events (native `subscribe` and i3 IPC SUBSCRIBE).
///
/// Events used to be written to subscribers one after another, AWAITING each write: a single
/// stuck subscriber (a paused process, a full socket buffer) stalled delivery to every subscriber
/// after it, and each new event queued one more suspended task behind it forever. i3 IPC sends
/// were fire-and-forget with no bound at all, so a stuck client grew memory without limit.
///
/// Now each send is issued without waiting (NWConnection keeps per-connection order), in-flight
/// sends are counted per connection, and a subscriber that falls `maxBacklog` events behind is
/// disconnected — the same thing i3 does to clients that stop reading.
@MainActor
enum EventBacklog {
    static let maxBacklog = 256
    private static var inFlight: [ObjectIdentifier: Int] = [:]

    /// Send `data` to `connection`; `onDrop` runs (once) if the subscriber is disconnected for
    /// falling behind or the send fails.
    static func send(_ data: Data, to connection: NWConnection, onDrop: @escaping @MainActor () -> Void) {
        let key = ObjectIdentifier(connection)
        let pending = inFlight[key, default: 0]
        if pending >= maxBacklog {
            inFlight.removeValue(forKey: key)
            connection.cancel()
            onDrop()
            return
        }
        inFlight[key] = pending + 1
        connection.send(content: data, completion: .contentProcessed { error in
            Task.startUnstructured { @MainActor in
                if let n = inFlight[key] { inFlight[key] = n > 1 ? n - 1 : nil }
                if error != nil {
                    inFlight.removeValue(forKey: key)
                    onDrop()
                }
            }
        })
    }

    static func backlog(of connection: NWConnection) -> Int { inFlight[ObjectIdentifier(connection)] ?? 0 }

    static func forget(_ connection: NWConnection) { inFlight.removeValue(forKey: ObjectIdentifier(connection)) }
}

/// Length-prefixed JSON frame used by the native socket protocol (see NWConnection.writeAtomic)
func nativeEventFrame(_ msg: some Encodable, _ encoder: JSONEncoder) -> Data? {
    guard let payload = try? encoder.encode(msg) else { return nil }
    var data = unsafe withUnsafeBytes(of: UInt32(payload.count)) { unsafe Data($0) }
    data.append(payload)
    return data
}
