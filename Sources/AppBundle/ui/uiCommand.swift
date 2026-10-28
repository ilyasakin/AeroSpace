import AppKit
import Common

/// A click in AeroSpace's own UI (status bar, menu bar, group tab bar, settings). It runs the same
/// command a hotkey, the CLI or i3 IPC would — parsed from arguments exactly like the CLI's — in a
/// light session. The UI itself only draws the model; it never changes it.
@MainActor
func runUiCommand(_ args: [String]) {
    guard let command = parseCommand(args).cmdOrNil else { return }
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled(orIsEnableCommand: command) else { return }
        _ = try? await runLightSession(.menuBarButton, token) {
            await command.run(.defaultEnv, .emptyStdin)
        }
    }
}
