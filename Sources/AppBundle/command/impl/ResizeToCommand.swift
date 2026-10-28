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
            window.requestFrame(topLeft: nil, size: size)
            return .succ
        }

        // Tiled: apply width/height as absolute weight targets when a tiles/master parent exists
        var ok = false
        if let hParent = window.parentsWithSelf
            .compactMap({ $0.parent as? TilingContainer })
            .first(where: { $0.orientation == .h && ($0.layout == .tiles || $0.layout == .master) })
        {
            let node = window.parentsWithSelf.first { $0.parent === hParent }.orDie()
            if hParent.layout == .master {
                ok = hParent.resizeMasterSplit(node, toPrimarySpan: width) || ok
            } else {
            let target = width * hParent.weightPerPixel(.h)
            let diff = target - node.getWeight(.h)
            if let childDiff = diff.div(hParent.children.count - 1) {
                hParent.children.lazy.filter { $0 !== node }.forEach {
                    $0.setWeight(.h, $0.getWeight(.h) - childDiff)
                }
                node.setWeight(.h, target)
                ok = true
            }
            }
        }
        if let vParent = window.parentsWithSelf
            .compactMap({ $0.parent as? TilingContainer })
            .first(where: { $0.orientation == .v && ($0.layout == .tiles || $0.layout == .master) })
        {
            let node = window.parentsWithSelf.first { $0.parent === vParent }.orDie()
            if vParent.layout == .master {
                ok = vParent.resizeMasterSplit(node, toPrimarySpan: height) || ok
            } else {
            let target = height * vParent.weightPerPixel(.v)
            let diff = target - node.getWeight(.v)
            if let childDiff = diff.div(vParent.children.count - 1) {
                vParent.children.lazy.filter { $0 !== node }.forEach {
                    $0.setWeight(.v, $0.getWeight(.v) - childDiff)
                }
                node.setWeight(.v, target)
                ok = true
            }
            }
        }
        if !ok {
            return .fail(io.err("resize-to could not adjust tiled weights; float the window or use resize"))
        }
        return .succ
    }
}

extension TilingContainer {
    /// Master layout splits its span by the master's weight against the AVERAGE stack weight
    /// (`masterLayoutChildRects`), so a pixel target maps through that split, not through the
    /// tiles ratio: `px × weightSum / span` gave a 500px master 800px. Adjusts only the master's
    /// weight — the master's span for the master, the stack pane's span for a stack window.
    @MainActor
    func resizeMasterSplit(_ node: TreeNode, toPrimarySpan target: CGFloat) -> Bool {
        guard layout == .master, children.count > 1, let index = children.firstIndex(where: { $0 === node }),
              let span = desiredRect?.getDimension(orientation)
              ?? nodeWorkspace?.projectedTileSize(of: self).map({ orientation == .h ? $0.width : $0.height })
        else { return false }
        let gap = nodeWorkspace.map { CGFloat($0.resolvedGaps.inner.get(orientation)) } ?? 0
        let usable = span - gap
        let stack = children.dropFirst().map { $0.getWeight(orientation) }
        let stackAverage = stack.reduce(0, +) / CGFloat(stack.count)
        let masterSpan = index == 0 ? target : usable - target
        guard usable > 0, masterSpan > 0, masterSpan < usable, stackAverage > 0 else { return false }
        // masterSpan = usable × m / (m + a)  ⇒  m = masterSpan × a / (usable − masterSpan)
        children[0].setWeight(orientation, masterSpan * stackAverage / (usable - masterSpan))
        return true
    }
}
