import AppKit
import Foundation

/// Windows of invisible workspaces are parked off-screen in a corner. A clean quit puts them back
/// (`beforeTermination`), but a crash or SIGKILL can't: they stayed off-screen with nothing to
/// bring them back. AeroSpace therefore runs a copy of itself in watchdog mode that only waits for
/// it to die. A clean quit stops the watchdog first; any other exit makes it move every mostly
/// off-screen window back onto the middle of a display.
public enum CrashWatchdog {
    static let flag = "--aerospace-crash-watchdog"
    @MainActor private static var process: Process?

    /// Call first thing at launch: in watchdog mode this never returns
    public static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
              let parent = pid_t(arguments[i + 1])
        else { return }
        waitForExit(of: parent)
        undimAllWindows()
        let moved = restoreParkedWindows()
        FileHandle.standardError.write("aerospace crash watchdog: parent \(parent) died, restored \(moved) windows\n".data(using: .utf8)!)
        exit(0)
    }

    @MainActor static func start() {
        guard Headless.permits(.spawnProcess), process == nil,
              let executable = Bundle.main.executableURL
        else { return }
        let p = Process()
        p.executableURL = executable
        p.arguments = [flag, String(myPid)]
        do {
            try p.run()
            process = p
        } catch {
            FrameTrace.log("crash-watchdog failed to start: \(error)")
        }
    }

    /// Clean quit: our own restore runs, the watchdog must not
    @MainActor static func stop() {
        process?.terminate()
        process = nil
    }

    private static func waitForExit(of pid: pid_t) {
        let kq = kqueue()
        guard kq >= 0 else { return }
        defer { close(kq) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        // ESRCH: already gone
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return }
        var event = kevent()
        while kevent(kq, nil, 0, &event, 1, nil) < 0, errno == EINTR {}
    }

    /// `dim-inactive-windows` darkening outlives the process that set it
    private static func undimAllWindows() {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { w -> UInt32? in
            (w[kCGWindowLayer as String] as? Int) == 0 ? (w[kCGWindowNumber as String] as? Int).map(UInt32.init) : nil
        }
        SkyLight.setBrightness(ids, 0)
    }

    /// Returns how many windows were moved
    private static func restoreParkedWindows() -> Int {
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return 0 }
        var moved = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else { continue }
            for window in windows {
                guard let rect = frame(of: window),
                      var target = parkedWindowRestoreOrigin(rect, displays: displays)
                else { continue }
                if AXValueCreate(.cgPoint, &target).map({ AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0) }) == .success {
                    moved += 1
                }
            }
        }
        return moved
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// Where to move a window the watchdog finds parked: nil when it is mostly on a display already.
/// "Parked" = less than a fifth of it on any display. It goes to the centre of the display nearest
/// to it (the one its parking corner belongs to), keeping its size. Global top-left coordinates.
func parkedWindowRestoreOrigin(_ rect: CGRect, displays: [CGRect]) -> CGPoint? {
    guard rect.width > 0, rect.height > 0, !displays.isEmpty else { return nil }
    let area = rect.width * rect.height
    let visible = displays.map { rect.intersection($0) }.reduce(CGFloat(0)) { $0 + ($1.isNull ? 0 : $1.width * $1.height) }
    guard visible < area / 5 else { return nil }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    func distance(_ d: CGRect) -> CGFloat {
        let dx = max(d.minX - center.x, 0, center.x - d.maxX)
        let dy = max(d.minY - center.y, 0, center.y - d.maxY)
        return dx * dx + dy * dy
    }
    let display = displays.min { distance($0) < distance($1) }!
    return CGPoint(
        x: display.minX + max((display.width - rect.width) / 2, 0),
        y: display.minY + max((display.height - rect.height) / 2, 0),
    )
}
