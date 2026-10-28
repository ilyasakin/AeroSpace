import AppKit
import Common

struct MarkCommand: Command {
    let args: MarkCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let mark = args.mark.val
        if args.toggle, window.marks.contains(mark) {
            window.marks.removeAll { $0 == mark }
            return .succ
        }
        window.setMark(mark, add: args.add)
        return .succ
    }
}

struct UnmarkCommand: Command {
    let args: UnmarkCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // With --window-id / a criteria target: only that window. Otherwise i3 semantics: the
        // named mark wherever it is, or every mark.
        let explicit = args.windowId != nil || env.windowId != nil
        let windows: [Window]
        if explicit {
            guard let target = args.resolveTargetOrReportError(env, io), let w = target.windowOrNil else { return .fail }
            windows = [w]
        } else {
            windows = Window.allWindowsForMarks
        }
        for w in windows {
            if let mark = args.mark { w.marks.removeAll { $0 == mark } } else { w.marks = [] }
        }
        return .succ
    }
}

struct MoveNodeToMarkCommand: Command {
    let args: MoveNodeToMarkCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let marked = Window.marked(args.mark.val) else { return .fail(io.err("No window is marked '\(args.mark.val)'")) }
        // The focused container moves when `focus parent` is active
        var node: TreeNode = window == focus.windowOrNil ? (focus.focusedNode ?? window) : window
        // The whole workspace root is not a movable node
        if node === window.nodeWorkspace?.rootTilingContainer { node = window }
        if node === marked || marked.isDescendant(of: node) { return .fail(io.err("Can't move a node into itself")) }
        guard let markedWs = marked.nodeWorkspace else { return .fail(io.err("The marked window isn't on a workspace")) }
        if marked.isFloating {
            // i3: the moved con becomes floating on the marked window's workspace
            if let w = node as? Window { w.bindAsFloatingWindow(to: markedWs) }
        } else if let parent = marked.parent as? TilingContainer, let index = marked.ownIndex {
            // i3 con_move_to_mark: right after the marked con, as its sibling
            let sameParentBefore = node.parent === parent && (node.ownIndex ?? Int.max) < index
            node.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index + 1 - (sameParentBefore ? 1 : 0))
        } else {
            return .fail(io.err("The marked window isn't tiled or floating"))
        }
        if args.focusFollowsWindow { return .from(bool: window.focusWindow()) }
        return .succ
    }
}

extension TreeNode {
    @MainActor func isDescendant(of ancestor: TreeNode) -> Bool {
        var p = parent
        while let node = p {
            if node === ancestor { return true }
            p = node.parent
        }
        return false
    }
}

/// `criteria ... -- command`: run the command once per matching window, targeted at it.
struct CriteriaCommand: Command {
    let args: CriteriaCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let matches = await windowsMatching(args.criteria)
        if matches.isEmpty { return .fail(io.err("No window matches the criteria")) }
        var ok = true
        for window in matches {
            // Bare `focus` is i3's "focus the matched window"
            let words = args.command == ["focus"] ? ["focus", "--window-id", String(window.windowId)] : args.command
            switch parseCommand(words) {
                case .cmd(let command):
                    let result = await command.run(env.withWindowId(window.windowId), .emptyStdin)
                    io.out(result.stdout)
                    io.err(result.stderr)
                    ok = ok && result.exitCode.rawValue == 0
                case .failure(let e): return .fail(io.err(e.msg))
                case .help(let h): io.out(h)
            }
        }
        return .from(bool: ok)
    }
}

@MainActor
func windowsMatching(_ criteria: [WindowCriterion]) async -> [Window] {
    let focused = focus.windowOrNil
    var result: [Window] = []
    for window in Window.allWindowsForMarks.sorted(by: { $0.windowId < $1.windowId }) {
        var matches = true
        for c in criteria {
            if !(await window.matches(c, focused: focused)) {
                matches = false
                break
            }
        }
        if matches { result.append(window) }
    }
    return result
}

extension Window {
    @MainActor func matches(_ c: WindowCriterion, focused: Window?) async -> Bool {
        func regex(_ value: String, _ subject: String?, focusedSubject: String?) -> Bool {
            guard let subject else { return false }
            if value == "__focused__" { return subject == focusedSubject }
            guard let re = try? NSRegularExpression(pattern: value) else { return subject == value }
            return re.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
        switch c.key {
            case .all: return true
            case .floating: return isFloating
            case .tiling: return parent is TilingContainer
            case .windowId:
                if c.value == "__focused__" { return self == focused }
                return c.value.flatMap(UInt32.init) == windowId
            case .mark:
                guard let value = c.value else { return false }
                return marks.contains { regex(value, $0, focusedSubject: nil) }
            case .workspace:
                return regex(c.value ?? "", nodeWorkspace?.name, focusedSubject: focused?.nodeWorkspace?.name)
            case .appName:
                return regex(c.value ?? "", app.name, focusedSubject: focused?.app.name)
            case .appId:
                let value = c.value ?? ""
                return regex(value, app.rawAppBundleId, focusedSubject: focused?.app.rawAppBundleId)
                    || regex(value, app.name, focusedSubject: focused?.app.name)
            case .title:
                let title = try? await getTitle(.nonCancellable)
                let focusedTitle: String? = if c.value == "__focused__" { try? await focused?.getTitle(.nonCancellable) } else { nil }
                return regex(c.value ?? "", title, focusedSubject: focusedTitle)
        }
    }
}
