import AppKit
import Darwin

/// macOS 27's App Intents daemon (`linkd`) "opens" apps in the background to read their intents —
/// AeroSpace included, though it is already running — and after a 30 s idle grace sends them a Quit
/// Apple Event, as if it had launched them itself. AppKit's default handler accepts any quit, so the
/// window manager vanished with no crash report ("Idle grace period elapsed for
/// bobko.aerospace.debug; asking launcher to terminate if appropriate").
///
/// This replaces AppKit's quit handler: a quit from `linkd` is refused, any other one (the user,
/// `osascript`, logout, restart, shutdown) quits as before.
@MainActor
enum QuitEventGuard {
    private static let handler = QuitAppleEventHandler()

    /// Call after AppKit has finished launching: it installs its own quit handler at launch, and the
    /// last registration wins
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            handler,
            andSelector: #selector(QuitAppleEventHandler.handleQuit(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication),
        )
    }
}

/// Pure: whether a Quit Apple Event should quit. `senderPath` is the sending process's executable;
/// `hasQuitReason` is true when the event says why (logout / restart / shutdown) — always honored.
func shouldHonorQuitAppleEvent(senderPath: String?, hasQuitReason: Bool) -> Bool {
    if hasQuitReason { return true }
    guard let senderPath else { return true }
    return (senderPath as NSString).lastPathComponent != "linkd"
}

private final class QuitAppleEventHandler: NSObject {
    @MainActor @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let hasQuitReason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
            || event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        let senderPath = pid.flatMap(executablePath(of:))
        if shouldHonorQuitAppleEvent(senderPath: senderPath, hasQuitReason: hasQuitReason) {
            NSApplication.shared.terminate(nil)
        } else {
            FrameTrace.log("quit-refused sender=\(senderPath ?? "?") pid=\(pid.map(String.init) ?? "?")")
        }
    }
}

private func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
