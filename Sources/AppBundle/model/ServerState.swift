import Common

/// Whether AeroSpace is managing windows (`enable on|off|toggle`). Model state: it lived in the
/// tray menu's view model, so every session gate, observer and command read a UI object to find
/// out whether the window manager was on. The tray mirrors it for SwiftUI.
@MainActor
enum ServerState {
    static var isEnabled: Bool = true {
        didSet {
            Kernel.noteModelMutation("isEnabled")
            TrayMenuModel.shared.isEnabled = isEnabled
        }
    }
}
