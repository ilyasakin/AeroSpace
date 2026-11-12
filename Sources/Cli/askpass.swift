import Common
import Darwin
import Foundation

/// `sudo -A` askpass: AeroSpace shows the password panel and the password is printed for sudo.
/// Exits 1 (sudo then fails) when cancelled, refused or AeroSpace is not running.
func runAskpass(prompt: String) -> Never {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1, err: "aerospace askpass: no socket") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(askpassSocketPath.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, c) in path.prefix(raw.count).enumerated() { unsafe raw[i] = UInt8(bitPattern: c) }
    }
    let connected = withUnsafePointer(to: &addr) {
        unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { exit(1, err: "aerospace askpass: AeroSpace is not running (\(askpassSocketPath))") }
    let request = askpassEncodeRequest(prompt: prompt)
    _ = unsafe request.withUnsafeBytes { unsafe write(fd, $0.baseAddress, $0.count) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = unsafe read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0 ..< n])
    }
    close(fd)
    switch AskpassReply.decode(reply) {
        case .password(let password):
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            exit(0)
        case .refused(let reason):
            exit(1, err: "aerospace askpass: \(reason)")
    }
}
