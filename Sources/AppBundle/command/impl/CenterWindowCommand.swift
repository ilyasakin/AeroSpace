import AppKit
import Common

struct CenterWindowCommand: Command {
    let args: CenterWindowCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        if !window.isFloating {
            window.bindAsFloatingWindow(to: target.workspace)
            if let size = window.lastFloatingSize { window.requestFrame(topLeft: nil, size: size) }
        }

        guard let monitor = window.nodeMonitor else {
            return .fail(io.err("Window \(window.windowId) doesn't belong to any monitor"))
        }
        guard let rect = try? await window.intendedFrame(.nonCancellable) else {
            return .fail(io.err("Failed to get window \(window.windowId) frame"))
        }
        let size = CGSize(width: rect.width, height: rect.height)
        let area = monitor.visibleRectPaddedByOuterGaps
        let topLeft = CGPoint(
            x: area.topLeftX + (area.width - size.width) / 2,
            y: area.topLeftY + (area.height - size.height) / 2,
        )
        window.requestFrame(topLeft: topLeft, size: nil)
        return .succ
    }
}
