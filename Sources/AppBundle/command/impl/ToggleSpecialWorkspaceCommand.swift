import AppKit
import Common

/// Remembers which workspace was active before a special workspace was summoned.
/// Keyed by **(monitor name, special workspace name)** so multi-monitor use does not clobber
/// another monitor's restore target.
@MainActor
enum SpecialWorkspaceToggleState {
    private static var remembered: [String: String] = [:]

    private static func key(special: String, monitor: String) -> String {
        "\(monitor)\u{1e}\(special)"
    }

    static func remembered(for special: String, onMonitor monitorName: String) -> String? {
        remembered[key(special: special, monitor: monitorName)]
    }

    static func remember(_ previous: String, for special: String, onMonitor monitorName: String) {
        remembered[key(special: special, monitor: monitorName)] = previous
    }

    static func clear(for special: String, onMonitor monitorName: String) {
        remembered.removeValue(forKey: key(special: special, monitor: monitorName))
    }

    /// Test/reset helper
    static func resetAll() { remembered.removeAll() }
}

struct ToggleSpecialWorkspaceCommand: Command {
    let args: ToggleSpecialWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let specialName = args.target.val.raw
        let special = Workspace.get(byName: specialName)
        let monitor = focus.workspace.workspaceMonitor
        let monitorKey = monitor.name
        let current = monitor.activeWorkspace

        if current == special {
            // Toggle back to remembered workspace (or fall back to previous focus)
            let backName = SpecialWorkspaceToggleState.remembered(for: specialName, onMonitor: monitorKey)
                ?? prevFocusedWorkspace?.name
            SpecialWorkspaceToggleState.clear(for: specialName, onMonitor: monitorKey)
            guard let backName else {
                return .fail(io.err("No workspace to return to from special workspace '\(specialName)'"))
            }
            let back = Workspace.get(byName: backName)
            if monitor.setActiveWorkspace(back) {
                return .from(bool: back.focusWorkspace())
            }
            return .fail(io.err("Can't return to workspace '\(backName)' on monitor '\(monitor.name)'"))
        }

        // Summon special onto focused monitor; remember what it replaces (per-monitor)
        SpecialWorkspaceToggleState.remember(current.name, for: specialName, onMonitor: monitorKey)
        let prevMonitor = special.isVisible ? special.workspaceMonitor : nil
        if monitor.setActiveWorkspace(special) {
            if let prevMonitor {
                // If the special was visible on another monitor, clear that monitor's restore
                // entry for this special — the workspace has moved.
                SpecialWorkspaceToggleState.clear(for: specialName, onMonitor: prevMonitor.name)
                let stubWorkspace = getStubWorkspace(for: prevMonitor)
                check(
                    prevMonitor.setActiveWorkspace(stubWorkspace),
                    "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(prevMonitor)",
                )
            }
            return .from(bool: special.focusWorkspace())
        } else {
            SpecialWorkspaceToggleState.clear(for: specialName, onMonitor: monitorKey)
            return .fail(io.err(
                "Can't move workspace '\(special.name)' to monitor '\(monitor.name)'. workspace-to-monitor-force-assignment doesn't allow it",
            ))
        }
    }
}
