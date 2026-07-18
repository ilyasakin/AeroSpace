import AppKit
import Common

struct ResizeToCommand: Command {
    let args: ResizeToCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        let width = CGFloat(args.width.val)
        let height = CGFloat(args.height.val)
        let size = CGSize(width: max(width, 10), height: max(height, 10))

        if window.isFloating {
            window.setAxFrame(nil, size)
            window.lastFloatingSize = size
            if var rect = window.lastAppliedLayoutPhysicalRect {
                rect = Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: size.width, height: size.height)
                window.lastAppliedLayoutPhysicalRect = rect
            }
            return .succ
        }

        // Tiled: apply width/height as absolute weight targets when a tiles/master parent exists
        var ok = false
        if let hParent = window.parentsWithSelf
            .compactMap({ $0.parent as? TilingContainer })
            .first(where: { $0.orientation == .h && ($0.layout == .tiles || $0.layout == .master) })
        {
            let node = window.parentsWithSelf.first { $0.parent === hParent }.orDie()
            let diff = width - node.getWeight(.h)
            if let childDiff = diff.div(hParent.children.count - 1) {
                hParent.children.lazy.filter { $0 !== node }.forEach {
                    $0.setWeight(.h, $0.getWeight(.h) - childDiff)
                }
                node.setWeight(.h, width)
                ok = true
            }
        }
        if let vParent = window.parentsWithSelf
            .compactMap({ $0.parent as? TilingContainer })
            .first(where: { $0.orientation == .v && ($0.layout == .tiles || $0.layout == .master) })
        {
            let node = window.parentsWithSelf.first { $0.parent === vParent }.orDie()
            let diff = height - node.getWeight(.v)
            if let childDiff = diff.div(vParent.children.count - 1) {
                vParent.children.lazy.filter { $0 !== node }.forEach {
                    $0.setWeight(.v, $0.getWeight(.v) - childDiff)
                }
                node.setWeight(.v, height)
                ok = true
            }
        }
        if !ok {
            return .fail(io.err("resize-to could not adjust tiled weights; float the window or use resize"))
        }
        return .succ
    }
}
