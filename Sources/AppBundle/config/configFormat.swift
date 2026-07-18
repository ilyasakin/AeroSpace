import Foundation

/// Detected config file syntax for the load path.
enum ConfigSourceFormat: Equatable, Sendable {
    case toml
    case hyprland
}

/// Decide TOML vs Hyprland after reading config text.
/// Primary: file extension (`.conf`/`.hypr` → Hyprland, `.toml` → TOML).
/// Fallback sniff for extension-less / unknown paths. When unsure, default to TOML.
func detectConfigFormat(text: String, url: URL?) -> ConfigSourceFormat {
    if let url {
        switch url.pathExtension.lowercased() {
            case "conf", "hypr": return .hyprland
            case "toml": return .toml
            default: break
        }
    }
    return sniffConfigFormat(text)
}

/// Conservative content sniff. Only returns Hyprland when early non-comment lines look like
/// Hyprland grammar and there is no clear TOML shape. Unsure → TOML.
func sniffConfigFormat(_ text: String) -> ConfigSourceFormat {
    var sawHyprland = false
    var sawToml = false
    var nonCommentLines = 0

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        if let hash = line.firstIndex(of: "#") {
            // TOML full-line comments and Hypr `#` comments — ignore trailing notes for sniff only when
            // the `#` starts the line (after trim). Inline `#` in TOML strings is rare at file start.
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
    }

    if sawHyprland && !sawToml {
        return .hyprland
    }
    return .toml
}

private func looksLikeTomlLine(_ trimmed: String) -> Bool {
    // Table header: [mode.main.binding] or [[on-window-detected]]
    if trimmed.hasPrefix("[") {
        return true
    }
    // Typical TOML dotted keys used by AeroSpace
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
    // Variable: $mainMod = SUPER
    if trimmed.hasPrefix("$"), trimmed.contains("=") {
        return true
    }
    // Section open: general {
    if trimmed.hasSuffix("{") {
        let name = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !name.contains("="), !name.contains("[") {
            return true
        }
    }
    // bind* = MOD, key, dispatcher
    let lower = trimmed.lowercased()
    for prefix in ["bind =", "binde =", "bindl =", "bindr =", "bindm =", "bindel =", "bindle =", "bindn =", "bindt ="] {
        if lower.hasPrefix(prefix) { return true }
    }
    // Common top-level hypr assignments (with or without spaces around `=`)
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
