import Common
import Foundation

let configDotfileName = ".aerospace.toml"

/// Resolve the **primary** config file.
///
/// Discovery rules (thesis: pristine Linux config + optional TOML sidecar):
/// 1. Forced `--config-path` wins alone.
/// 2. `~/.aerospace.toml` is always a full native primary (eject / classic install).
/// 3. If an i3/Hyprland config exists, it is the primary — even when
///    `~/.config/aerospace/aerospace.toml` also exists (that file is the **sidecar** only).
/// 4. Else XDG `aerospace.toml` is the native primary.
func findCustomConfigUrl() -> ConfigFile {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: ".config/")
    return resolveCustomConfigUrl(
        home: home,
        xdgConfigHome: xdg,
        forcedConfigLocation: serverArgs.configLocation,
    )
}

/// Pure discovery used by production and tests. `fileExists` defaults to the real filesystem.
func resolveCustomConfigUrl(
    home: URL,
    xdgConfigHome: URL,
    forcedConfigLocation: String?,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
) -> ConfigFile {
    if let forced = forcedConfigLocation {
        let url = URL(filePath: forced)
        return fileExists(url) ? .file(url) : .noCustomConfigExists
    }

    let homeDot = home.appending(path: configDotfileName)
    if fileExists(homeDot) {
        return .file(homeDot)
    }

    let linuxExisting = linuxCompatConfigCandidates(xdgConfigHome: xdgConfigHome, home: home)
        .map(\.url)
        .filter(fileExists)
    if let first = linuxExisting.first {
        return .file(first)
    }

    let xdgToml = aerospaceTomlSidecarUrl(xdgConfigHome: xdgConfigHome, home: home)
    if fileExists(xdgToml) {
        return .file(xdgToml)
    }
    return .noCustomConfigExists
}

/// Sidecar path for macOS-only extras when the primary config is an i3/Hyprland dialect.
func findTomlSidecarUrl(primaryConfigUrl: URL) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: ".config/")
    return resolveTomlSidecarUrl(
        primaryConfigUrl: primaryConfigUrl,
        home: home,
        xdgConfigHome: xdg,
    )
}

/// Pure sidecar resolution (disk + dialect). Used by production and discovery tests.
func resolveTomlSidecarUrl(
    primaryConfigUrl: URL,
    home: URL,
    xdgConfigHome: URL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    readText: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) },
) -> URL? {
    let sidecar = aerospaceTomlSidecarUrl(xdgConfigHome: xdgConfigHome, home: home)
    guard fileExists(sidecar) else { return nil }
    if sidecar.standardizedFileURL == primaryConfigUrl.standardizedFileURL {
        return nil
    }
    let homeDot = home.appending(path: configDotfileName)
    if homeDot.standardizedFileURL == primaryConfigUrl.standardizedFileURL {
        return nil
    }
    let format = detectConfigFormat(
        text: readText(primaryConfigUrl) ?? "",
        url: primaryConfigUrl,
    )
    guard format == .i3 || format == .hyprland else { return nil }
    return sidecar
}

/// Load primary via discovery and apply TOML sidecar when primary is a Linux dialect.
/// Mirrors `readConfig` → `parseConfigText` composition with injectable roots for tests.
@MainActor
func parseConfigFromDiscovery(
    home: URL,
    xdgConfigHome: URL,
    forcedConfigLocation: String? = nil,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    readText: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) },
) -> ParseConfigResult? {
    switch resolveCustomConfigUrl(
        home: home,
        xdgConfigHome: xdgConfigHome,
        forcedConfigLocation: forcedConfigLocation,
        fileExists: fileExists,
    ) {
        case .file(let primaryUrl):
            guard let text = readText(primaryUrl) else { return nil }
            let format = detectConfigFormat(text: text, url: primaryUrl)
            let primary: ParseConfigResult = switch format {
                case .toml:
                    parseConfig(text)
                case .hyprland:
                    parseImportedDialectForDiscovery(text, kind: "hyprland", importHyprConfig)
                case .i3:
                    parseImportedDialectForDiscovery(text, kind: "i3", importI3Config)
            }
            guard format != .toml,
                  let sidecar = resolveTomlSidecarUrl(
                      primaryConfigUrl: primaryUrl,
                      home: home,
                      xdgConfigHome: xdgConfigHome,
                      fileExists: fileExists,
                      readText: readText,
                  )
            else {
                return primary
            }
            return applyTomlSidecar(primary: primary, sidecarUrl: sidecar)
        case .noCustomConfigExists, .ambiguousConfigError:
            return nil
    }
}

@MainActor
private func parseImportedDialectForDiscovery(
    _ text: String,
    kind: String,
    _ importer: (String, ImportOptions) -> ImportResult,
) -> ParseConfigResult {
    let imported = importer(text, ImportOptions())
    let parsed = parseConfig(imported.toml)
    let importWarnings = imported.diagnostics.map { diagnostic in
        ConfigParseDiagnostic(.emptyRoot, "\(kind) import: \(diagnostic.description)")
    }
    return ParseConfigResult(
        config: parsed.config,
        errors: parsed.errors,
        warnings: importWarnings + parsed.warnings,
    )
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
