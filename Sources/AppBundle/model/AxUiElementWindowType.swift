import AppKit

enum AxUiElementWindowType: String {
    /// Tiled by default
    case window
    /// Floating by default
    case dialog
    /// Not even a real window. AeroSpace doesn't manage it at all
    case popup
}

// Covered by tests in ./axDumps in the repo root
//
// The classification is intentionally app-agnostic ("protocol semantics", inspired by how X11 window
// managers consume EWMH hints). It never special-cases particular applications. If the verdict is
// wrong for some app, users fix it with 'window-detection-rules' in their config - the same way i3
// users write 'for_window' rules - instead of waiting for a hardcoded exception in a new release.
//
// The signals and their X11 analogs:
// - macOS window level        ~ override-redirect (tooltips, PiP, overlays live at elevated levels)
// - AXModal                   ~ _NET_WM_STATE_MODAL / WM_TRANSIENT_FOR
// - AXSubrole                 ~ _NET_WM_WINDOW_TYPE
// - AXSize settability        ~ fixed-size windows (min size == max size WM_NORMAL_HINTS)
// - activation policy         ~ dock/panel window types
extension AxUiElementMock {
    func getWindowType(
        axApp: AxUiElementMock,
        _ activationPolicy: NSApplication.ActivationPolicy,
        _ windowLevel: MacOsWindowLevel?,
    ) -> AxUiElementWindowType {
        // Note: a lot of windows don't have title on startup, so please don't rely on the title
        lazy var closeButton = get(Ax.closeButtonAttr)
        lazy var fullscreenButton = get(Ax.fullscreenButtonAttr)
        lazy var zoomButton = get(Ax.zoomButtonAttr)
        lazy var minimizeButton = get(Ax.minimizeButtonAttr)
        lazy var anyButton = closeButton != nil || fullscreenButton != nil || zoomButton != nil || minimizeButton != nil
        lazy var subrole = get(Ax.subroleAttr)
        // "provably resizable". false means "not settable OR unknown" (old AX dumps don't carry
        // writability info, and AXUIElementIsAttributeSettable may fail)
        lazy var sizeSettable = isSettable(Ax.sizeAttr) == true
        lazy var focusedish = get(Ax.isFocused) == true ||
            get(Ax.isMainAttr) == true ||
            axApp.get(Ax.focusedWindowAttr)?.windowId == containingWindowId()

        // Overlay level (PiP windows, miniplayers, quick terminals, notification pills).
        // Such windows position themselves; don't manage them at all
        if windowLevel == .alwaysOnTopWindow {
            return .popup
        }

        // Sheets are glued to their parent window (~ WM_TRANSIENT_FOR): buttonless yet resizable,
        // so without this check they fall through every branch below to .window and reserve an
        // empty tile next to the parent (Electron file pickers open NSOpenPanel as a sheet)
        if get(Ax.roleAttr) == kAXSheetRole {
            return .dialog
        }

        // Accessory apps (no Dock icon) provide panel-like windows:
        // buttonless ones are popups (e.g. Raycast, zebar), buttoned ones are floating dialogs
        // (e.g. "About This Mac", NoMachine)
        if activationPolicy == .accessory {
            if closeButton == nil && !sizeSettable {
                return .popup
            }
            if anyButton {
                return .dialog
            }
        }

        if get(Ax.modalAttr) == true {
            return .dialog
        }

        // Elevated non-overlay levels (modal panels at level 8, alerts at 101+):
        // real dialogs if they show window chrome or hold focus, UI debris otherwise
        if case .unknown = windowLevel {
            return anyButton || focusedish ? .dialog : .popup
        }

        // Buttonless AXWindows that are not standard windows, not resizable, and not the app's
        // main window are UI debris: tooltips, context menus, keyboard layout switcher,
        // "find in page" bars, Electron popups
        if !anyButton && subrole != kAXStandardWindowSubrole && !sizeSettable && get(Ax.isMainAttr) != true {
            return .popup
        }

        // Dialog-subrole windows with a disabled close button are quick-open style popups
        // (Xcode "Open Quickly", Xcode "Quick Actions")
        if subrole == kAXDialogSubrole, let closeButton, closeButton.get(Ax.enabledAttr) != true {
            return .popup
        }

        // Provably fixed-size windows that are not fullscreen-capable float: tiling must resize,
        // and these refuse. X11 analog: i3 floats windows whose WM_NORMAL_HINTS pin min == max
        // (confirm/exit dialogs — JetBrains' JBR exposes them as buttonless AXUnknown windows,
        // Swing/AWT as standard-chrome ones; both are fixed-size and never fullscreen-capable).
        // Fullscreen-capable means an enabled fullscreen button or a settable AXFullScreen —
        // "designed to go big" (iPhone Simulator, mpv borderless fullscreen) stays tiled.
        // `isSettable == false` is a proven "not settable"; old dumps / failed AX probes stay
        // unknown (nil) and fall through — never reclassifies on missing information.
        if isSettable(Ax.sizeAttr) == false,
           fullscreenButton?.get(Ax.enabledAttr) != true,
           isSettable(Ax.isFullscreenAttr) != true
        {
            return .dialog
        }

        // Float windows that declare a dialog-ish subrole (macOS native file picker, telegram
        // image viewer, Finder Quick Look)
        if subrole != kAXStandardWindowSubrole && anyButton {
            return .dialog
        }

        // Heuristic: float windows that are not designed to be big:
        // - fullscreen button present but disabled (Safari "Log in with Google", Kap, flameshot)
        // - fullscreen button absent while other window chrome is present but disabled
        //   (Calculator, System Settings-style fixed panels, IntelliJ dialogs)
        if let fullscreenButton {
            if fullscreenButton.get(Ax.enabledAttr) != true {
                return .dialog
            }
        } else if anyButton {
            let anyDisabledChromeButton = [closeButton, zoomButton, minimizeButton]
                .contains { button in button != nil && button?.get(Ax.enabledAttr) != true }
            if anyDisabledChromeButton {
                return .dialog
            }
        }

        return .window
    }
}
