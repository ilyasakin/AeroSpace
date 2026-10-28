import AppKit
import Common

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let result = await reloadConfig_nonCancellable(args: args)
        if !result.stdout.isEmpty {
            io.out(result.stdout)
        }
        if !result.stderr.isEmpty {
            io.err(result.stderr)
        }
        return .from(bool: result.isOk)
    }
}

struct ReloadConfigResult {
    let isOk: Bool
    let stdout: String
    let stderr: String
}

@MainActor func reloadConfig_nonCancellable(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
) async -> ReloadConfigResult {
    let result = readConfig(forceConfigUrl: forceConfigUrl)
    let parseResult = result.parseConfigResult
    let warningsAsErrors = args.warningsAsErrors

    var errors = parseResult.errors.map { $0.description(.error) }
    var warnings = parseResult.warnings.map { $0.description(.warning) }
    let containsWarnings = !parseResult.warnings.isEmpty

    let willApply = parseResult.allowReloadConfig && !args.dryRun

    if !args.noGui {
        let lines = errors + warnings
        switch true {
            case !errors.isEmpty:
                // "Failed to parse" alone was misleading whenever the config was applied ANYWAY.
                // Only a severe error (a TOML syntax error) sets preventConfigReload; everything
                // else — an unparseable key, an unknown command in a binding — is recoverable, so
                // the offending entries are dropped and the rest of the config takes effect. The
                // dialog said "Failed", the user assumed their old config was still live, and in
                // fact some of their keys had silently stopped existing. Say which it was.
                let msg = failedToParseMsg(
                    configUrl: result.configUrl,
                    errorsCount: parseResult.errors.count,
                    warningsCount: parseResult.warnings.count,
                    lines: lines,
                    applied: willApply,
                    droppedBindings: willApply ? parseResult.droppedBindingDescriptions : [],
                )
                MessageModel.shared.message = Message(body: msg, containsWarnings: containsWarnings)
            case warningsAsErrors && !warnings.isEmpty:
                let msg = parsedWithWarningsMsg(configUrl: result.configUrl, warningsCount: parseResult.warnings.count, lines: lines)
                MessageModel.shared.message = Message(body: msg, containsWarnings: containsWarnings)
            default:
                MessageModel.shared.message = nil
        }
    }
    if willApply {
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = containsWarnings
        resetHotKeys()
        config = parseResult.config
        resetRuntimeGapsOverrides() // i3: `gaps` changes last until reload
        SystemServices.setWindowServerReadsEnabled(config.skyLightReads)
        configUrl = result.configUrl
        await activateMode_nonCancellable(activeMode)
        syncStartAtLogin()
        syncFocusFollowsMouse(config)
        syncConfigFileWatcher()
    }

    if warningsAsErrors {
        errors += warnings
        warnings = []
    }

    return ReloadConfigResult(
        isOk: errors.isEmpty,
        stdout: errors.joined(separator: "\n\n"),
        stderr: warnings.joined(separator: "\n\n"),
    )
}

/// `applied` distinguishes the two very different outcomes that both used to read "Failed to parse":
/// a severe error (TOML syntax) rejects the file and leaves the running config untouched, while any
/// recoverable error applies the rest of the config and drops only the offending entries. Reporting
/// both as a flat failure led users to believe their previous config was still live when parts of it
/// had in fact just been removed.
/// Internal rather than private so tests can assert the exact text the user is shown — the whole
/// point of this function is that the two outcomes must not read the same.
func failedToParseMsg(
    configUrl: URL,
    errorsCount: Int,
    warningsCount: Int,
    lines: [String],
    applied: Bool,
    droppedBindings: [String],
) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let counts = "\(errorsCount) error(s). \(warningsCount) warning(s)"
    var parts: [String] = []
    if applied {
        parts.append("Applied \(path) with errors. \(counts)")
        parts.append("The rest of the config took effect, but everything listed below was skipped.")
        if !droppedBindings.isEmpty {
            let list = droppedBindings.sorted().map { "  \($0)" }.joined(separator: "\n")
            parts.append("These key bindings could not be parsed and NO LONGER WORK:\n\(list)")
        }
    } else {
        parts.append("Failed to parse \(path). \(counts)")
        parts.append("Nothing was applied — the previously loaded config is still active.")
    }
    parts.append(lines.joined(separator: "\n\n"))
    return parts.joined(separator: "\n\n")
}

private func parsedWithWarningsMsg(configUrl: URL, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Parsed \(path) with \(warningsCount) warning(s). Feel free to close this window."
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}
