import Common
import Foundation

/// Session-pipeline counters (diagnostics; read via `debug-windows`). Main-actor only.
@MainActor
enum SessionStats {
    static var echoesSuppressed = 0
    static var heavyByCause: [String: Int] = [:]
    static var lightSessions = 0

    static func noteHeavy(_ event: RefreshSessionEvent) {
        heavyByCause[event.statsCause, default: 0] += 1
    }

    static var report: String {
        let heavies = heavyByCause.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "sessions: light=\(lightSessions) echoes-suppressed=\(echoesSuppressed) heavy{\(heavies)}"
    }

    static func resetForTests() {
        echoesSuppressed = 0
        heavyByCause = [:]
        lightSessions = 0
    }
}

extension RefreshSessionEvent {
    /// Coarse bucket for heavy-session accounting
    var statsCause: String {
        switch self {
            case .ax(let notif): "ax:\(notif)"
            case .globalObserver(let notif): "observer:\(notif)"
            case .globalObserverLeftMouseUp: "mouse-up"
            case .configAutoReload: "config"
            case .menuBarButton: "menu"
            case .hotkeyBinding: "hotkey"
            case .startup: "startup"
            case .socketServer: "cli"
            case .i3IpcRunCommand: "i3ipc"
            case .resetManipulatedWithMouse: "mouse-reset"
            case .focusFollowsMouse: "ffm"
        }
    }
}

extension RefreshSessionEvent {
    /// A user command (hotkey, CLI, i3 IPC, menu) rather than a notification
    var isCommand: Bool {
        switch self {
            case .hotkeyBinding, .socketServer, .i3IpcRunCommand, .menuBarButton: true
            case .ax, .globalObserver, .globalObserverLeftMouseUp, .configAutoReload, .startup,
                 .resetManipulatedWithMouse, .focusFollowsMouse: false
        }
    }
}
