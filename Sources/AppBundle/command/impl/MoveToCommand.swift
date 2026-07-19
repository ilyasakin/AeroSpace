import AppKit
import Common

struct MoveToCommand: Command {
    let args: MoveToCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        if !window.isFloating {
            window.bindAsFloatingWindow(to: target.workspace)
            if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
            FloatLayer.didBecomeFloating(window)
            io.err("move-to floated the tiled window before placing it")
        }

        let topLeft = CGPoint(x: CGFloat(args.x.val), y: CGFloat(args.y.val))
        window.setAxFrame(topLeft, nil)
        if let size = try? await window.getAxSize(.nonCancellable) {
            window.lastAppliedLayoutPhysicalRect = Rect(
                topLeftX: topLeft.x,
                topLeftY: topLeft.y,
                width: size.width,
                height: size.height,
            )
            window.lastFloatingSize = size
        } else {
            window.lastAppliedLayoutPhysicalRect = nil
        }
        return .succ
    }
}
