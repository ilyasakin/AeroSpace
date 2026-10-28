import AppKit
import Common

struct FocusBackAndForthCommand: Command {
    let args: FocusBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // The previous window closed: falling back to its workspace's focus switched workspace
        // instead of saying so
        if let id = prevFocusedWindowId, Window.get(byId: id) == nil { return .fail(io.err("Prev window has been closed")) }
        return switch prevFocus {
            case let prevFocus?: .from(bool: setFocus(to: prevFocus))
            case nil: .fail(io.err("Prev window has been closed"))
        }
    }
}
