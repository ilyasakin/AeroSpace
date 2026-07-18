import AppKit
import Common
import Foundation

/// First-run notice when a Linux WM config is the primary config (auto-discovered).
/// Plug-and-play: we already run the file live — this only informs and offers optional eject.
@MainActor
func offerForeignConfigImportIfNeeded() async {
    if isUnitTest || serverArgs.isReadOnly { return }
    // Only when the live primary is a discovered i3/Hyprland file (not forced path, not native TOML).
    guard serverArgs.configLocation == nil else { return }
    guard case .file(let primaryUrl) = findCustomConfigUrl() else { return }
    let format = detectConfigFormat(
        text: (try? String(contentsOf: primaryUrl, encoding: .utf8)) ?? "",
        url: primaryUrl,
    )
    guard format == .i3 || format == .hyprland else { return }

    let noticeKey = "aerospace.linuxCompatConfigNoticeShown"
    if UserDefaults.standard.bool(forKey: noticeKey) { return }

    let sidecar = aerospaceTomlSidecarUrl()
    let kind = format == .i3 ? "i3" : "Hyprland"
    let alert = NSAlert()
    alert.messageText = "Using your \(kind) config"
    alert.informativeText =
        "AeroSpace is running \(primaryUrl.path) directly — keybindings and rules load at runtime.\n\n" +
        "Optional: eject to native TOML if you want macOS-only features (borders, status bar, etc.) " +
        "in one file, or add a small TOML sidecar at \(sidecar.path) that overlays the Linux config.\n\n" +
        "Linux status bars (polybar/i3status/i3bar) do not run on macOS; use the first-party bar or i3 IPC tooling."
    alert.addButton(withTitle: "Got It")
    alert.addButton(withTitle: "Eject to TOML…")
    let response = alert.runModal()
    UserDefaults.standard.set(true, forKey: noticeKey)
    guard response == .alertSecondButtonReturn else { return }

    guard let sourceText = try? String(contentsOf: primaryUrl, encoding: .utf8) else { return }
    let result: ImportResult = format == .i3
        ? importI3Config(sourceText, ImportOptions())
        : importHyprConfig(sourceText, ImportOptions())
    do {
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.toml.write(to: sidecar, atomically: true, encoding: .utf8)
    } catch {
        let failure = NSAlert()
        failure.messageText = "Eject failed"
        failure.informativeText = error.localizedDescription
        failure.runModal()
        return
    }
    _ = await reloadConfig_nonCancellable()

    let done = NSAlert()
    done.messageText = "Ejected to TOML"
    done.informativeText =
        "\(result.translatedCount) of \(result.directiveCount) directives translated, \(result.skippedCount) skipped.\n\n" +
        "Written to \(sidecar.path). The native TOML is now the primary config. " +
        "Run 'aerospace import-config \(format == .i3 ? "i3" : "hyprland") --dry-run' any time to review a conversion."
    done.runModal()
}
