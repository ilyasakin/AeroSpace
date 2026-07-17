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

    var editedUrl: URL? {
        switch findCustomConfigUrl() {
            case .file(let url): url
            case .noCustomConfigExists, .ambiguousConfigError: nil
        }
    }

    /// (Re-)reads the config from disk into the model. Creates ~/.aerospace.toml from the
    /// bundled default config if the user has no config file yet (same behavior as "Open config")
    func load() {
        lastError = nil
        let url: URL
        switch findCustomConfigUrl() {
            case .file(let existing):
                url = existing
            case .noCustomConfigExists:
                let fallback = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
                _ = try? FileManager.default.copyItem(atPath: defaultConfigUrl.path, toPath: fallback.path)
                url = fallback
            case .ambiguousConfigError(let candidates):
                lastError = "Ambiguous config: several config files found:\n" + candidates.map(\.path).joined(separator: "\n")
                return
        }
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
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.menuBarButton, token) {
                _ = await reloadConfig_nonCancellable(args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true))
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
