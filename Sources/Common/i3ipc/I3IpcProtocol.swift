import Foundation

// MARK: - Message / event type numbers (i3-ipc(7))

public enum I3IpcMessageType: UInt32, Sendable {
    case runCommand = 0
    case getWorkspaces = 1
    case subscribe = 2
    case getOutputs = 3
    case getTree = 4
    case getMarks = 5
    case getBarConfig = 6
    case getVersion = 7
    case getBindingModes = 8
    case getConfig = 9
    case sendTick = 10
    case sync = 11
}

public enum I3IpcEventType: UInt32, Sendable {
    case workspace = 0
    case output = 1
    case mode = 2
    case window = 3
    case barconfigUpdate = 4
    case binding = 5
    case shutdown = 6
    case tick = 7

    /// Wire type with high bit set (events are pushed as replies with this type).
    public var wireType: UInt32 { 0x8000_0000 | rawValue }

    public init?(eventName: String) {
        switch eventName.lowercased() {
            case "workspace": self = .workspace
            case "output": self = .output
            case "mode": self = .mode
            case "window": self = .window
            case "barconfig_update": self = .barconfigUpdate
            case "binding": self = .binding
            case "shutdown": self = .shutdown
            case "tick": self = .tick
            default: return nil
        }
    }

    public var eventName: String {
        switch self {
            case .workspace: "workspace"
            case .output: "output"
            case .mode: "mode"
            case .window: "window"
            case .barconfigUpdate: "barconfig_update"
            case .binding: "binding"
            case .shutdown: "shutdown"
            case .tick: "tick"
        }
    }
}

// MARK: - Framing

/// i3 IPC magic string (6 bytes): "i3-ipc"
public let i3IpcMagic = Data("i3-ipc".utf8)
public let i3IpcHeaderSize = 14 // 6 + 4 + 4

public struct I3IpcFrame: Equatable, Sendable {
    public var type: UInt32
    public var payload: Data

    public init(type: UInt32, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public init(message: I3IpcMessageType, payload: Data = Data()) {
        self.type = message.rawValue
        self.payload = payload
    }

    public init(event: I3IpcEventType, payload: Data = Data()) {
        self.type = event.wireType
        self.payload = payload
    }

    public var isEvent: Bool { type & 0x8000_0000 != 0 }

    public var payloadString: String {
        String(data: payload, encoding: .utf8) ?? ""
    }
}

/// Encode one i3 IPC frame: magic + payload_len (u32 LE) + type (u32 LE) + payload.
public func i3IpcEncodeFrame(_ frame: I3IpcFrame) -> Data {
    var data = Data()
    data.append(i3IpcMagic)
    var len = UInt32(frame.payload.count).littleEndian
    var typ = frame.type.littleEndian
    withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &typ) { data.append(contentsOf: $0) }
    data.append(frame.payload)
    return data
}

public enum I3IpcDecodeError: Error, Equatable, CustomStringConvertible {
    case truncated
    case badMagic
    case payloadTooLarge(UInt32)

    public var description: String {
        switch self {
            case .truncated: "truncated i3-ipc frame"
            case .badMagic: "bad i3-ipc magic"
            case .payloadTooLarge(let n): "i3-ipc payload too large: \(n)"
        }
    }
}

/// Decode one complete frame from the front of `buffer`. On success, removes consumed bytes.
public func i3IpcDecodeFrame(from buffer: inout Data) -> Result<I3IpcFrame, I3IpcDecodeError> {
    if buffer.count < i3IpcHeaderSize {
        return .failure(.truncated)
    }
    let magic = buffer.prefix(6)
    if magic != i3IpcMagic {
        return .failure(.badMagic)
    }
    let len: UInt32 = buffer.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 6, as: UInt32.self).littleEndian
    }
    let typ: UInt32 = buffer.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 10, as: UInt32.self).littleEndian
    }
    // Cap payload at 16 MiB to avoid runaway allocations from a bad client.
    if len > 16 * 1024 * 1024 {
        return .failure(.payloadTooLarge(len))
    }
    let total = i3IpcHeaderSize + Int(len)
    if buffer.count < total {
        return .failure(.truncated)
    }
    let payload = buffer.subdata(in: i3IpcHeaderSize ..< total)
    buffer.removeSubrange(0 ..< total)
    return .success(I3IpcFrame(type: typ, payload: payload))
}

// MARK: - Socket path / version

/// Separate from AeroSpace's own CLI socket (`socketPath`).
public let i3IpcSocketPath = "/tmp/\(aeroSpaceAppId)-\(unixUserName)-i3.sock"

/// IPC API level advertised to version-gating i3 tools (i3 4.x wire compatibility).
public let i3IpcCompatMajor = 4
public let i3IpcCompatMinor = 22
public let i3IpcCompatPatch = 0

public func i3IpcVersionPayload(productVersion: String = aeroSpaceAppVersion) -> [String: Any] {
    [
        "major": i3IpcCompatMajor,
        "minor": i3IpcCompatMinor,
        "patch": i3IpcCompatPatch,
        "human_readable": "AeroSpace \(productVersion) (i3-ipc compatible)",
        "loaded_config_file_name": "",
    ]
}

// MARK: - Workspace num rule (i3 convention)

/// i3 `num`: integer prefix of the workspace name when present, else `-1` for named workspaces.
/// Examples: `"3"` → 3, `"3:web"` → 3, `"web"` → -1, `"12foo"` → 12.
public func i3WorkspaceNum(from name: String) -> Int {
    var digits = ""
    for ch in name {
        if ch.isNumber {
            digits.append(ch)
        } else {
            break
        }
    }
    guard !digits.isEmpty, let n = Int(digits) else { return -1 }
    return n
}

// MARK: - Pure JSON builders (testable without AppKit tree)

public struct I3RectDTO: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var asDict: [String: Any] {
        ["x": x, "y": y, "width": width, "height": height]
    }
}

public struct I3WorkspaceDTO: Equatable, Sendable {
    public var num: Int
    public var name: String
    public var visible: Bool
    public var focused: Bool
    public var urgent: Bool
    public var output: String
    public var rect: I3RectDTO

    public init(num: Int, name: String, visible: Bool, focused: Bool, urgent: Bool, output: String, rect: I3RectDTO) {
        self.num = num
        self.name = name
        self.visible = visible
        self.focused = focused
        self.urgent = urgent
        self.output = output
        self.rect = rect
    }

    public var asDict: [String: Any] {
        [
            "num": num,
            "name": name,
            "visible": visible,
            "focused": focused,
            "urgent": urgent,
            "output": output,
            "rect": rect.asDict,
        ]
    }
}

public struct I3OutputDTO: Equatable, Sendable {
    public var name: String
    public var active: Bool
    public var primary: Bool
    public var rect: I3RectDTO
    public var currentWorkspace: String?

    public init(name: String, active: Bool, primary: Bool, rect: I3RectDTO, currentWorkspace: String?) {
        self.name = name
        self.active = active
        self.primary = primary
        self.rect = rect
        self.currentWorkspace = currentWorkspace
    }

    public var asDict: [String: Any] {
        [
            "name": name,
            "active": active,
            "primary": primary,
            "rect": rect.asDict,
            "current_workspace": currentWorkspace as Any,
        ]
    }
}

public func i3JsonData(_ object: Any) -> Data {
    // JSONSerialization requires Any that is valid JSON graph
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("null".utf8)
}

public func i3JsonString(_ object: Any) -> String {
    String(data: i3JsonData(object), encoding: .utf8) ?? "null"
}
