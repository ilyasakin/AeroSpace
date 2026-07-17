import AppKit
import Common
import Foundation

/// First-run experience: no user config exists, but an i3 or Hyprland config does.
/// Offer to import it instead of silently running on the default config
@MainActor
func offerForeignConfigImportIfNeeded() async {
    if isUnitTest || serverArgs.isReadOnly { return }
    guard case .noCustomConfigExists = findCustomConfigUrl() else { return }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: ".config/")
    let candidates: [(kind: String, url: URL, importer: (String, ImportOptions) -> ImportResult)] = [
        ("i3", xdgConfigHome.appending(path: "i3/config"), importI3Config),
        ("i3", home.appending(path: ".i3/config"), importI3Config),
        ("Hyprland", xdgConfigHome.appending(path: "hypr/hyprland.conf"), importHyprConfig),
    ]
    guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.url.path) }) else { return }
    guard let sourceText = try? String(contentsOf: found.url, encoding: .utf8) else { return }

    let alert = NSAlert()
    alert.messageText = "Import your \(found.kind) config?"
    alert.informativeText =
        "No AeroSpace config found, but a \(found.kind) config exists at \(found.url.path).\n\n" +
        "AeroSpace can translate it: keybindings, window rules, gaps and workspace assignments " +
        "are imported; lines that don't apply on macOS are kept as explained comments."
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let result = found.importer(sourceText, ImportOptions())
    let destination = xdgConfigHome.appending(path: "aerospace").appending(path: "aerospace.toml")
    do {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.toml.write(to: destination, atomically: true, encoding: .utf8)
    } catch {
        let failure = NSAlert()
        failure.messageText = "Import failed"
        failure.informativeText = error.localizedDescription
        failure.runModal()
        return
    }
    _ = await reloadConfig_nonCancellable()

    let done = NSAlert()
    done.messageText = "Config imported"
    done.informativeText =
        "\(result.translatedCount) of \(result.directiveCount) directives translated, \(result.skippedCount) skipped.\n\n" +
        "Written to \(destination.path). Skipped lines are preserved as comments at the bottom of the file, " +
        "each with an explanation. Run 'aerospace import-config \(found.kind == "i3" ? "i3" : "hyprland") --dry-run' any time to review."
    done.runModal()
}
