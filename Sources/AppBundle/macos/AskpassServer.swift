import Common
import Darwin
import Foundation

/// What the password panel shows. Everything here comes from the kernel, not from the client:
/// the client's pid is the socket peer (LOCAL_PEERPID), its parent must be the real `sudo`, and
/// the command and requester are read from the process table. A client cannot dress up a request.
struct AskpassRequest: Equatable, Sendable {
    /// sudo's own prompt ("Password:"); attempts after a wrong password say so
    let prompt: String
    /// The user the command runs as ("root" unless sudo -u)
    let runAs: String
    /// The command sudo will run, argv
    let command: [String]
    /// Who started sudo, nearest first: ["zsh (8721)", "claude (3213)", "Ghostty (1318)"]
    let requesters: [String]
    /// The sudo process, to tell a retry (same sudo asking again) from a new request
    let sudoPid: pid_t
}

/// One process, as far as askpass needs to know it
struct AskpassProcess: Equatable, Sendable {
    let pid: pid_t
    let parentPid: pid_t
    let realUid: uid_t
    let executablePath: String
    let arguments: [String]

    var name: String { askpassProgramName(executablePath) }
}

/// A program's display name: its file name, unless that is only a version (Claude Code installs
/// as `…/claude/versions/2.1.322`), then the directory that names the program
func askpassProgramName(_ path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    guard let last = parts.last else { return path }
    guard !last.contains(where: \.isLetter) else { return last }
    let parents = parts.dropLast().reversed().filter { $0 != "versions" && $0 != "bin" && $0.contains(where: \.isLetter) }
    return parents.first ?? last
}

/// The process that asked, for the prompt's one-line label: the nearest requester that is not a shell
func askpassRequesterLabel(_ requesters: [String]) -> String {
    let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "login", "nu", "sudo"]
    let names = requesters.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
    return names.first { !shells.contains($0) } ?? names.first ?? "sudo"
}

enum AskpassVerdict: Equatable {
    case ask(AskpassRequest)
    case refuse(String)
}

/// Decides whether a peer may ask, from a process lookup (production: the kernel; tests: a table)
func askpassVerdict(
    peerPid: pid_t,
    prompt: String,
    ownUid: uid_t,
    lookup: (pid_t) -> AskpassProcess?,
) -> AskpassVerdict {
    guard let peer = lookup(peerPid) else { return .refuse("the asking process is gone") }
    guard peer.realUid == ownUid else { return .refuse("the asking process belongs to another user") }
    guard let sudo = lookup(peer.parentPid), sudo.executablePath == "/usr/bin/sudo" else {
        return .refuse("only sudo may ask for a password (run it as SUDO_ASKPASS for sudo -A)")
    }
    // sudo runs setuid root on behalf of a real user: that must be this user
    guard sudo.realUid == ownUid else { return .refuse("that sudo was started by another user") }
    let parsed = sudoCommand(sudo.arguments)
    // Never ask for a password without showing what it unlocks
    guard !parsed.command.isEmpty else { return .refuse("could not read the command sudo would run") }
    var requesters: [String] = []
    var pid = sudo.parentPid
    while pid > 1, requesters.count < 4, let p = lookup(pid) {
        requesters.append("\(p.name) (\(p.pid))")
        pid = p.parentPid
    }
    return .ask(AskpassRequest(prompt: prompt, runAs: parsed.runAs, command: parsed.command, requesters: requesters, sudoPid: sudo.pid))
}

/// The target user and command from sudo's argv (`sudo -A -u bob -- ls -la` → bob, [ls, -la])
func sudoCommand(_ argv: [String]) -> (runAs: String, command: [String]) {
    let withValue: Set<String> = ["-u", "-g", "-p", "-C", "-h", "-U", "-r", "-t", "-T", "-D", "-R"]
    var runAs = "root"
    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a == "--" { i += 1; break }
        guard a.hasPrefix("-"), a.count > 1 else { break }
        if withValue.contains(a) {
            if a == "-u", i + 1 < argv.count { runAs = argv[i + 1] }
            i += 2
            continue
        }
        if a.hasPrefix("-u"), a.count > 2 { runAs = String(a.dropFirst(2)) } // -ubob
        i += 1
    }
    return (runAs, Array(argv.dropFirst(min(i, argv.count))))
}

/// The process table, read from the kernel. For a setuid-root `sudo` the full PROC_PIDTBSDINFO is
/// refused to its user, but the short info (real uid, parent), its path and its arguments are
/// readable (verified on macOS 27.2).
func askpassLookupProcess(_ pid: pid_t) -> AskpassProcess? {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    guard unsafe proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
    let executable = pathLength > 0 ? String(cString: path) : ""
    return AskpassProcess(pid: pid, parentPid: pid_t(info.pbsi_ppid), realUid: info.pbsi_ruid, executablePath: executable, arguments: processArguments(pid))
}

private func processArguments(_ pid: pid_t) -> [String] {
    let direct = kernelProcessArguments(pid)
    return direct.isEmpty ? psProcessArguments(pid) : direct
}

/// Same-user processes. A setuid-root process (sudo) is refused to its user (EINVAL)
private func kernelProcessArguments(_ pid: pid_t) -> [String] {
    var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var argmaxSize = MemoryLayout<Int32>.size
    guard unsafe sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return [] }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = Int(argmax)
    var buffer = [UInt8](repeating: 0, count: size)
    guard unsafe sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    let argc = unsafe buffer.withUnsafeBytes { unsafe $0.loadUnaligned(as: Int32.self) }
    var i = MemoryLayout<Int32>.size
    while i < size, buffer[i] != 0 { i += 1 } // executable path
    while i < size, buffer[i] == 0 { i += 1 } // padding
    var args: [String] = []
    while i < size, args.count < Int(argc) {
        let start = i
        while i < size, buffer[i] != 0 { i += 1 }
        args.append(String(decoding: buffer[start ..< i], as: UTF8.self))
        i += 1
    }
    return args
}

/// The system's setuid /bin/ps can read a root process's arguments; it joins them with spaces, so
/// an argument containing a space reads as two (display only)
private func psProcessArguments(_ pid: pid_t) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ww", "-o", "args=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ").map(String.init)
}

/// The askpass socket. One thread accepts; each request is answered from the main actor's panel.
/// Runs outside the kernel on purpose: a prompt waits for the user, and a kernel job waiting that
/// long would stall every command and event.
enum AskpassServer {
    nonisolated(unsafe) private static var started = false

    @MainActor static func start() {
        guard Headless.permits(.socketListener), !started else { return }
        started = true
        unlink(askpassSocketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(askpassSocketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        unsafe withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in path.enumerated() { raw[i] = UInt8(bitPattern: c) }
        }
        let bound = unsafe withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only this user may connect
        guard bound == 0, chmod(askpassSocketPath, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                Task.detached { await serve(client) }
            }
        }
        thread.name = "AskpassServer"
        thread.start()
    }

    private static func serve(_ fd: Int32) async {
        defer { close(fd) }
        var peer: pid_t = 0
        var peerSize = socklen_t(MemoryLayout<pid_t>.size)
        guard unsafe getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerSize) == 0 else { return }
        guard let prompt = readLine(fd) else { return }
        let reply: AskpassReply
        switch askpassVerdict(peerPid: peer, prompt: prompt, ownUid: getuid(), lookup: askpassLookupProcess) {
            case .refuse(let reason):
                FrameTrace.log("askpass refused pid \(peer): \(reason)")
                reply = .refused(reason)
            case .ask(let request):
                FrameTrace.log("askpass from \(request.requesters.first ?? "?") for \(request.command.first ?? "?")")
                let password = await AskpassPanel.shared.ask(request)
                reply = password.map(AskpassReply.password) ?? .refused("cancelled")
        }
        var data = reply.encoded
        _ = unsafe data.withUnsafeBytes { unsafe write(fd, $0.baseAddress, $0.count) }
        data.resetBytes(in: 0 ..< data.count)
    }

    /// The request line, at most 4 KiB, 30 s to arrive
    private static func readLine(_ fd: Int32) -> String? {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 4096 {
            guard unsafe read(fd, &byte, 1) == 1 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
