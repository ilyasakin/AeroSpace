import Common
import Foundation
import SwiftUI
import TOMLDecoder

/// Backing model of the in-app Settings window.
///
/// The TOML text of the config file is the single source of truth. Structured controls
/// read from the last successfully parsed `Config` and write by surgically patching the
/// text (TomlPatcher), so the user's comments and formatting survive GUI edits.
@MainActor
final class ConfigSettingsModel: ObservableObject {
    static let shared = ConfigSettingsModel()
    private init() {}

    @Published var text: String = ""
    @Published var parsedConfig: Config = defaultConfig
    @Published var errors: [String] = []
    @Published var warnings: [String] = []
    @Published var configPath: String = ""
    /// Set when the last GUI edit produced a config that failed to parse (should not happen -
    /// GUI edits are validated before writing) or the file couldn't be read/written
    @Published var lastError: String? = nil

    /// Always a native TOML path — never an i3/Hyprland primary. When the live WM runs a Linux
    /// dialect, Settings edits the TOML sidecar (`~/.config/aerospace/aerospace.toml`).
    var editedUrl: URL? { settingsTomlUrl() }

    /// (Re-)reads the Settings TOML from disk. Creates a native TOML file if missing
    /// (full default config when no Linux primary; empty sidecar stub when i3/Hypr is live).
    func load() {
        lastError = nil
        let url = ensureSettingsTomlFile()
        configPath = url.path
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            lastError = "Can't read \(url.path): \(error.localizedDescription)"
            return
        }
        reparse()
    }

    private func reparse() {
        let result = parseConfig(text)
        errors = result.errors.map { $0.description(.error) }
        warnings = result.warnings.map { $0.description(.warning) }
        if result.errors.isEmpty {
            parsedConfig = result.config
        }
    }

    /// Applies a text transformation, validates the result, writes it to disk, and reloads
    /// the live config. Rejects (and reports) transformations that break the config.
    func apply(_ transform: (String) -> String) {
        let newText = transform(text)
        if newText == text { return }
        let result = parseConfig(newText)
        if !result.errors.isEmpty {
            lastError = "Rejected edit, it would break the config:\n" + result.errors.map { $0.description(.error) }.joined(separator: "\n")
            return
        }
        save(newText)
    }

    /// Writes `newText` to disk without structural validation (used by the raw editor,
    /// which shows diagnostics instead of rejecting) and reloads the live config
    func save(_ newText: String) {
        guard let url = editedUrl else {
            load() // creates the file, then retry once
            guard let url = editedUrl else { return }
            write(newText, to: url)
            return
        }
        write(newText, to: url)
    }

    private func write(_ newText: String, to url: URL) {
        do {
            try newText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Can't write \(url.path): \(error.localizedDescription)"
            return
        }
        lastError = nil
        text = newText
        reparse()
        // Notify SwiftUI immediately — bindings read text/parsedConfig.
        objectWillChange.send()
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.menuBarButton, token) {
                _ = await reloadConfig_nonCancellable(args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true))
                // Bar modules/layout must refresh even if the light session skipped a full redraw.
                StatusBarManager.shared.refresh()
            }
        }
    }

    // MARK: - Typed bindings for structured controls

    func boolBinding(_ table: [String], _ key: String, get: @escaping (Config) -> Bool) -> Binding<Bool> {
        Binding(
            get: { [weak self] in get(self?.parsedConfig ?? defaultConfig) },
            set: { [weak self] newValue in
                self?.apply { TomlPatcher.setValue($0, table: table, key: key, rawValue: TomlPatcher.serialize(bool: newValue)) }
            },
        )
    }

    func intBinding(_ table: [String], _ key: String, get: @escaping (Config) -> Int) -> Binding<Int> {
        Binding(
            get: { [weak self] in get(self?.parsedConfig ?? defaultConfig) },
            set: { [weak self] newValue in
                self?.apply { TomlPatcher.setValue($0, table: table, key: key, rawValue: TomlPatcher.serialize(int: newValue)) }
            },
        )
    }

    func stringChoiceBinding(_ table: [String], _ key: String, get: @escaping (Config) -> String) -> Binding<String> {
        Binding(
            get: { [weak self] in get(self?.parsedConfig ?? defaultConfig) },
            set: { [weak self] newValue in
                self?.apply { TomlPatcher.setValue($0, table: table, key: key, rawValue: TomlPatcher.serialize(string: newValue)) }
            },
        )
    }

    /// Array-of-strings config key (e.g. bar.modules-left). One entry per line in the editor.
    /// Reads the raw TOML when present so GUI and file stay in lockstep; falls back to the
    /// effective parsed defaults when the key is still missing from the file.
    func stringArrayBinding(_ table: [String], _ key: String, get: @escaping (Config) -> [String]) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                if let raw = TomlPatcher.getRawValue(self.text, table: table, key: key) {
                    return parseTomlStringOrStringArray(raw).joined(separator: "\n")
                }
                return get(self.parsedConfig).joined(separator: "\n")
            },
            set: { [weak self] newValue in
                let items = newValue
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // Always write an explicit array (including `[]`) — removing the key would
                // resurrect Config defaults and look like the edit "reset".
                self?.apply {
                    TomlPatcher.setValue(
                        $0,
                        table: table,
                        key: key,
                        rawValue: TomlPatcher.serialize(stringArray: items),
                    )
                }
            },
        )
    }

    /// Replace a string-array key immediately (used by module chips that commit on click).
    func setStringArray(_ table: [String], _ key: String, _ items: [String]) {
        apply {
            TomlPatcher.setValue(
                $0,
                table: table,
                key: key,
                rawValue: TomlPatcher.serialize(stringArray: items),
            )
        }
    }

    /// Multi-command config callbacks (after-startup-command, on-focus-changed, ...) edited
    /// as one command per line. Empty text removes the key
    func commandListBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                guard let raw = TomlPatcher.getRawValue(self.text, table: [], key: key) else { return "" }
                return parseTomlStringOrStringArray(raw).joined(separator: "\n")
            },
            set: { [weak self] newValue in
                let commands = newValue.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                self?.apply {
                    switch commands.count {
                        case 0: TomlPatcher.removeKey($0, table: [], key: key)
                        case 1: TomlPatcher.setValue($0, table: [], key: key, rawValue: TomlPatcher.serialize(string: commands[0]))
                        default: TomlPatcher.setValue($0, table: [], key: key, rawValue: TomlPatcher.serialize(stringArray: commands))
                    }
                }
            },
        )
    }
}

// MARK: - Settings always edits native TOML (or sidecar)

/// Prefer existing native TOML paths; never return an i3/Hyprland primary.
@MainActor
func settingsTomlUrl() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dot = home.appending(path: configDotfileName)
    let xdg = aerospaceTomlSidecarUrl()
    if FileManager.default.fileExists(atPath: dot.path) { return dot }
    if FileManager.default.fileExists(atPath: xdg.path) { return xdg }
    // Prefer XDG path for new files (sidecar-friendly when a Linux config is primary).
    return xdg
}

@MainActor
private func ensureSettingsTomlFile() -> URL {
    let url = settingsTomlUrl()
    if FileManager.default.fileExists(atPath: url.path) {
        return url
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // If the live primary is already a Linux dialect, start a minimal sidecar (overlay).
    // Otherwise seed the full default native config (same as historical Settings behavior).
    let primaryIsLinux: Bool = {
        guard case .file(let primary) = findCustomConfigUrl() else { return false }
        let fmt = detectConfigFormat(
            text: (try? String(contentsOf: primary, encoding: .utf8)) ?? "",
            url: primary,
        )
        return fmt == .i3 || fmt == .hyprland
    }()
    if primaryIsLinux {
        let stub = """
            # AeroSpace TOML sidecar — macOS extras overlaid on your i3/Hyprland config.
            # Edited by Settings. Keys here override the primary Linux config.

            [bar]
            enabled = false
            """
        try? stub.write(to: url, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.copyItem(at: defaultConfigUrl, to: url)
    }
    return url
}

/// Best-effort reader for raw TOML values that are either a string or an array of strings.
/// Only used to prefill GUI editors; the authoritative parse is parseConfig
func parseTomlStringOrStringArray(_ raw: String) -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // TOMLDecoder can't parse a bare value, wrap it into a throwaway document
    guard let table = try? TOMLTable(source: "x = \(trimmed)"), let dict = try? [String: Any](table) else { return [] }
    if let arr = dict["x"] as? [Any] {
        return arr.compactMap { $0 as? String }
    }
    if let str = dict["x"] as? String {
        return [str]
    }
    return []
}
