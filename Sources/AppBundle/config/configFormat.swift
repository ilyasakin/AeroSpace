import Foundation

/// Detected config file syntax for the load path.
enum ConfigSourceFormat: Equatable, Sendable {
    case toml
    case hyprland
    case i3
}

/// Decide TOML vs Hyprland vs i3 after reading config text.
/// Primary: path/extension heuristics, then content sniff. When unsure, default to TOML.
func detectConfigFormat(text: String, url: URL?) -> ConfigSourceFormat {
    if let url {
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()
        switch ext {
            case "toml": return .toml
            case "hypr": return .hyprland
            case "conf":
                // `.conf` alone is ambiguous (Hyprland *and* some i3 copies). Prefer content.
                let sniffed = sniffConfigFormat(text)
                if sniffed != .toml { return sniffed }
                // Path hints when content is empty/unsure
                if path.contains("/i3/") || path.hasSuffix("/.i3/config") { return .i3 }
                if path.contains("/hypr/") || path.contains("hyprland") { return .hyprland }
                return .hyprland // legacy default for bare .conf
            default: break
        }
        // i3 standard paths: ~/.config/i3/config, ~/.i3/config (often no extension)
        if path.contains("/i3/config") || path.hasSuffix("/.i3/config") || path.hasSuffix("/i3/config") {
            return .i3
        }
        if path.contains("/hypr/") || path.hasSuffix("hyprland.conf") {
            return .hyprland
        }
    }
    return sniffConfigFormat(text)
}

/// Conservative content sniff. Prefer an explicit dialect only when early non-comment lines
/// look like that grammar and not like TOML. Unsure → TOML.
func sniffConfigFormat(_ text: String) -> ConfigSourceFormat {
    var sawHyprland = false
    var sawI3 = false
    var sawToml = false
    var nonCommentLines = 0

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        if let hash = line.firstIndex(of: "#") {
            let beforeHash = line[..<hash].trimmingCharacters(in: .whitespaces)
            if beforeHash.isEmpty {
                continue
            }
            line = String(beforeHash)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        nonCommentLines += 1
        if nonCommentLines > 40 { break }

        if looksLikeTomlLine(trimmed) {
            sawToml = true
        }
        if looksLikeHyprlandLine(trimmed) {
            sawHyprland = true
        }
        if looksLikeI3Line(trimmed) {
            sawI3 = true
        }
    }

    if sawToml { return .toml }
    // Hyprland and i3 can both use `bind` / `set` — prefer Hypr when its stronger markers appear
    if sawHyprland { return .hyprland }
    if sawI3 { return .i3 }
    return .toml
}

private func looksLikeTomlLine(_ trimmed: String) -> Bool {
    if trimmed.hasPrefix("[") {
        return true
    }
    if trimmed.hasPrefix("config-version")
        || trimmed.hasPrefix("after-startup-command")
        || trimmed.hasPrefix("start-at-login")
        || trimmed.hasPrefix("enable-normalization")
        || trimmed.hasPrefix("default-root-container")
        || trimmed.hasPrefix("key-mapping")
        || trimmed.hasPrefix("exec.")
        || trimmed.hasPrefix("gaps.")
        || trimmed.hasPrefix("mode.")
    {
        return true
    }
    return false
}

private func looksLikeHyprlandLine(_ trimmed: String) -> Bool {
    if trimmed.hasPrefix("$"), trimmed.contains("=") {
        return true
    }
    if trimmed.hasSuffix("{") {
        let name = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !name.contains("="), !name.contains("[") {
            return true
        }
    }
    let lower = trimmed.lowercased()
    for prefix in ["bind =", "binde =", "bindl =", "bindr =", "bindm =", "bindel =", "bindle =", "bindn =", "bindt ="] {
        if lower.hasPrefix(prefix) { return true }
    }
    if lower.hasPrefix("bind=")
        || lower.hasPrefix("binde=")
        || lower.hasPrefix("exec-once")
        || lower.hasPrefix("windowrule")
        || lower.hasPrefix("monitor=")
        || lower.hasPrefix("monitor =")
        || lower.hasPrefix("env =")
        || lower.hasPrefix("env=")
    {
        return true
    }
    return false
}

private func looksLikeI3Line(_ trimmed: String) -> Bool {
    let lower = trimmed.lowercased()
    // Classic i3 directives (word at start of line)
    let prefixes = [
        "set $", "bindsym ", "bindcode ", "mode \"", "mode '", "mode ",
        "workspace_layout", "default_orientation", "for_window ",
        "assign ", "workspace ", "floating_modifier", "focus_follows_mouse",
        "gaps ", "smart_gaps", "smart_borders", "font ", "bar {",
        "exec_always ", "exec --no-startup-id", "client.focused",
        "hide_edge_borders", "popup_during_fullscreen",
    ]
    for p in prefixes {
        if lower.hasPrefix(p) { return true }
    }
    // `set $mod Mod4` style without space after set when `$`
    if lower.hasPrefix("set $") { return true }
    if lower.hasPrefix("set ") && trimmed.contains("$") { return true }
    return false
}

/// Well-known Linux WM config paths used when no native AeroSpace config exists.
func linuxCompatConfigCandidates(xdgConfigHome: URL? = nil, home: URL? = nil) -> [(kind: String, url: URL)] {
    let home = home ?? FileManager.default.homeDirectoryForCurrentUser
    let xdg = xdgConfigHome
        ?? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: ".config/")
    return [
        ("i3", xdg.appending(path: "i3/config")),
        ("i3", home.appending(path: ".i3/config")),
        ("Hyprland", xdg.appending(path: "hypr/hyprland.conf")),
    ]
}

/// Default path for native TOML (and for the macOS-extras sidecar when primary is a Linux dialect).
func aerospaceTomlSidecarUrl(xdgConfigHome: URL? = nil, home: URL? = nil) -> URL {
    let home = home ?? FileManager.default.homeDirectoryForCurrentUser
    let xdg = xdgConfigHome
        ?? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? home.appending(path: ".config/")
    return xdg.appending(path: "aerospace").appending(path: "aerospace.toml")
}
