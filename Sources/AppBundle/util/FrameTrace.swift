import Foundation

/// Debug builds only: a line per frame-write event, to diagnose windows that don't end up where
/// layout put them. `~/Library/Application Support/<debug app id>/frame-trace.log`, capped.
enum FrameTrace {
    private static let queue = DispatchQueue(label: "bobko.aerospace.frame-trace", qos: .utility)
    nonisolated(unsafe) private static var lines = 0

    static func log(_ message: @autoclosure () -> String) {
        guard isDebug, !Headless.isActive else { return }
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + message() + "\n"
        queue.async {
            unsafe lines += 1
            let count = unsafe lines
            let url = AppSupportDir.file("frame-trace.log")
            if count == 1 || count > 20000 {
                unsafe lines = 1
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            // The throwing API: the legacy `seekToEndOfFile()` / `write(_:)` raise an Objective-C
            // exception on failure, which Swift can't catch — a full disk (ENOSPC) aborted the whole
            // window manager from inside its debug log. A line that can't be written is dropped.
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }
}

func fmt(_ r: Rect?) -> String {
    guard let r else { return "nil" }
    return "(\(fmt(r.topLeftX)),\(fmt(r.topLeftY)) \(fmt(r.width))x\(fmt(r.height)))"
}

/// Never `Int(_:)` in a trace: an unconstrained learned cap is `.infinity`, and that conversion traps
func fmt(_ v: CGFloat) -> String {
    v.isFinite ? String(Int(v.rounded())) : (v.isNaN ? "nan" : "inf")
}
