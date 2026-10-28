import AppKit
import Common

struct SwapCommand: Command {
    let args: SwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else {
            return .fail
        }

        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }

        let targetWindow: Window?
        if let mark = args.withMark {
            guard let marked = Window.marked(mark) else { return .fail(io.err("No window is marked '\(mark)'")) }
            if marked == currentWindow { return .succ }
            // Swapping with a window macOS owns (minimized / hidden / native fullscreen) would bind
            // the visible one into the parking container and tile the parked one
            let swappable = { (w: Window) in w.parent is TilingContainer || w.isFloating }
            guard swappable(marked), swappable(currentWindow) else {
                return .fail(io.err("Only tiled or floating windows can be swapped"))
            }
            swapWindows(mruDominant: currentWindow, marked)
            return args.swapFocus ? .from(bool: marked.focusWindow()) : .succ
        }
        switch args.target.orDie() {
            case .direction(let direction):
                switch currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    case let (parent, ownIndex)?:
                        targetWindow = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil where args.wrapAround:
                        targetWindow = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil:
                        return .fail
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return .fail
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    if !args.wrapAround {
                        return .fail
                    }
                    targetIndex = (targetIndex + windows.count) % windows.count
                }
                targetWindow = windows[targetIndex]
        }

        guard let targetWindow else {
            return .fail
        }

        swapWindows(mruDominant: currentWindow, targetWindow)

        if args.swapFocus {
            return .from(bool: targetWindow.focusWindow())
        }
        return .succ
    }
}
