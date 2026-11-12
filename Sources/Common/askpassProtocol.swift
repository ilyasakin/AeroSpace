import Foundation

/// `sudo -A` askpass served by AeroSpace (the macOS counterpart of a polkit agent): `sudo` runs
/// `aerospace askpass "<prompt>"`, which asks the AeroSpace server to show its password panel.
/// AeroSpace never runs anything privileged itself; it only returns the typed password to the
/// `sudo` that asked. Separate socket from the command socket: the server needs the caller's pid
/// from the kernel (LOCAL_PEERPID), which Network.framework does not expose.
public let askpassSocketPath = "/tmp/\(aeroSpaceAppId)-\(unixUserName)-askpass.sock"

/// Request: the prompt sudo passed, one line. Reply: `OK\n<password>\n` or `NO\n<reason>\n`.
public enum AskpassReply: Equatable, Sendable {
    case password(String)
    case refused(String)

    public var encoded: Data {
        switch self {
            case .password(let p): Data("OK\n\(p)\n".utf8)
            case .refused(let reason): Data("NO\n\(oneLine(reason))\n".utf8)
        }
    }

    public static func decode(_ data: Data) -> AskpassReply {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return .refused("malformed reply from AeroSpace") }
        var body = String(lines[1])
        if body.hasSuffix("\n") { body.removeLast() }
        return lines[0] == "OK" ? .password(body) : .refused(body.isEmpty ? "refused" : body)
    }
}

public func askpassEncodeRequest(prompt: String) -> Data { Data("\(oneLine(prompt))\n".utf8) }

private func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}
