import Common

/// The i3 'for_window' analog. Unlike on-window-detected (which runs commands after the window is
/// bound), these rules override the window/dialog/popup classification itself, so they can also
/// rescue windows that would otherwise be ignored as popups.
enum WindowDetectionVerdict: String, Equatable, Sendable {
    case tile
    case float
    case ignore

    var windowType: AxUiElementWindowType {
        switch self {
            case .tile: .window
            case .float: .dialog
            case .ignore: .popup
        }
    }
}

struct WindowDetectionRule: ConvenienceMutable, Equatable, Sendable {
    var matcher: WindowDetectionRuleMatcher = WindowDetectionRuleMatcher()
    var rawTreatAs: WindowDetectionVerdict? = nil

    var treatAs: WindowDetectionVerdict {
        rawTreatAs ?? dieT("ID-2B45A1C7 should have discarded nil")
    }

    var debugJson: Json {
        .dict([
            "matcher": matcher.debugJson,
            "treat-as": .string(treatAs.rawValue),
        ])
    }
}

struct WindowDetectionRuleMatcher: ConvenienceMutable, Equatable, Sendable {
    var appId: String?
    var appNameRegexSubstring: CaseInsensitiveRegex?
    var windowTitleRegexSubstring: CaseInsensitiveRegex?
    var windowSubrole: String?
    var windowLevel: MacOsWindowLevel?
    var duringAeroSpaceStartup: Bool?

    var isEmpty: Bool { self == WindowDetectionRuleMatcher() }

    var debugJson: Json {
        var resultParts: [String] = []
        if let appId {
            resultParts.append("appId=\"\(appId)\"")
        }
        if let appNameRegexSubstring {
            resultParts.append("appNameRegexSubstring=\"\(appNameRegexSubstring.origin)\"")
        }
        if let windowTitleRegexSubstring {
            resultParts.append("windowTitleRegexSubstring=\"\(windowTitleRegexSubstring.origin)\"")
        }
        if let windowSubrole {
            resultParts.append("windowSubrole=\"\(windowSubrole)\"")
        }
        if let windowLevel {
            resultParts.append("windowLevel=\(windowLevel.toJson())")
        }
        if let duringAeroSpaceStartup {
            resultParts.append("duringAeroSpaceStartup=\(duringAeroSpaceStartup)")
        }
        return .string(resultParts.joined(separator: ", "))
    }

    @MainActor
    func matches(
        appId actualAppId: String?,
        appName: String?,
        windowTitle: String?,
        windowSubrole actualSubrole: String?,
        windowLevel actualWindowLevel: MacOsWindowLevel?,
        isStartup actualIsStartup: Bool,
    ) -> Bool {
        if let duringAeroSpaceStartup, duringAeroSpaceStartup != actualIsStartup {
            return false
        }
        if let appId, appId != actualAppId {
            return false
        }
        if let appNameRegexSubstring, !(appName ?? "").contains(caseInsensitiveRegex: appNameRegexSubstring) {
            return false
        }
        if let windowTitleRegexSubstring, (windowTitle ?? "").contains(caseInsensitiveRegex: windowTitleRegexSubstring) != true {
            return false
        }
        if let windowSubrole, windowSubrole != actualSubrole {
            return false
        }
        if let windowLevel, windowLevel != actualWindowLevel {
            return false
        }
        return true
    }
}

func parseWindowDetectionRulesArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [WindowDetectionRule] {
    if let array = raw.asArrayOrNil {
        return array.enumerated().map { (index, raw) in parseWindowDetectionRule(raw, backtrace + .index(index), &c) }.filterNotNil()
    } else {
        c.errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return []
    }
}

private let windowDetectionRuleParser: [String: any ParserProtocol<WindowDetectionRule>] = [
    "if": Parser(\.matcher, parseRuleMatcher),
    "treat-as": Parser(\.rawTreatAs, upcast(parseTreatAs)),
]

private let ruleMatcherParsers: [String: any ParserProtocol<WindowDetectionRuleMatcher>] = [
    "app-id": Parser(\.appId, upcast(parseString)),
    "app-name-regex-substring": Parser(\.appNameRegexSubstring, upcast(parseCasInsensitiveRegex)),
    "window-title-regex-substring": Parser(\.windowTitleRegexSubstring, upcast(parseCasInsensitiveRegex)),
    "window-subrole": Parser(\.windowSubrole, upcast(parseString)),
    "window-level": Parser(\.windowLevel, upcast(parseWindowLevel)),
    "during-aerospace-startup": Parser(\.duringAeroSpaceStartup, upcast(parseBool)),
]

private func upcast<T>(
    _ fun: @escaping @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>,
) -> @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T?> {
    { fun($0, $1).map(Optional.init) }
}

private func parseCasInsensitiveRegex(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<CaseInsensitiveRegex> {
    parseString(raw, backtrace).flatMap { CaseInsensitiveRegex.new($0).toParsedConfig(backtrace) }
}

private func parseTreatAs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WindowDetectionVerdict> {
    parseString(raw, backtrace).flatMap {
        if let verdict = WindowDetectionVerdict(rawValue: $0) {
            return .success(verdict)
        }
        return .failure(.init(backtrace, "'\($0)' is invalid 'treat-as' value. Possible values: 'tile', 'float', 'ignore'"))
    }
}

private func parseWindowLevel(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<MacOsWindowLevel> {
    switch raw {
        case .int(let level):
            return .success(.new(windowLevel: Int(level)))
        default:
            return parseString(raw, backtrace).flatMap {
                switch $0 {
                    case "normal": .success(.normalWindow)
                    case "always-on-top": .success(.alwaysOnTopWindow)
                    default: .failure(.init(backtrace, "'\($0)' is invalid 'window-level' value. Possible values: 'normal', 'always-on-top' or a raw integer window level"))
                }
            }
    }
}

private func parseRuleMatcher(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WindowDetectionRuleMatcher {
    switch raw {
        case .dict(let raw):
            return raw.parseTable(WindowDetectionRuleMatcher(), ruleMatcherParsers, backtrace, &c)
        default:
            c.errors.append(.init(backtrace, expectedActualTypeError(expected: .table, actual: raw.tomlType)))
            return WindowDetectionRuleMatcher()
    }
}

private func parseWindowDetectionRule(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WindowDetectionRule? {
    var myContext = ConfigParserContext(configVersion: c.configVersion, errors: [], warnings: [])
    let rule = parseTable(raw, WindowDetectionRule(), windowDetectionRuleParser, backtrace, &myContext)

    if myContext.errors.isEmpty { // Don't stack "mandatory key" diagnostics on top of parse failures
        if rule.matcher.isEmpty {
            myContext.errors.append(.init(backtrace, "'if' is mandatory key. A rule that matches all windows is error prone"))
        }
        if rule.rawTreatAs == nil { // ID-2B45A1C7
            myContext.errors.append(.init(backtrace, "'treat-as' is mandatory key. Possible values: 'tile', 'float', 'ignore'"))
        }
    }

    if !myContext.errors.isEmpty {
        c.errors += myContext.errors
        c.warnings += myContext.warnings
        return nil
    }

    return rule
}
