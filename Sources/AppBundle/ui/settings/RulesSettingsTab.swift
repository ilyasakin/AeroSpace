import Common
import SwiftUI

/// Editors for [[window-detection-rules]] and [[on-window-detected]].
/// Unlike the scalar tabs, these edit local drafts and rewrite the whole section on Apply,
/// because entries are order-sensitive arrays of tables.
struct RulesSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel
    @State private var detectionRules: [DetectionRuleDraft] = []
    @State private var callbacks: [CallbackDraft] = []
    @State private var dirty = false
    @State private var applyError: String? = nil

    var body: some View {
        if !model.errors.isEmpty {
            VStack {
                Label("Fix the config errors first (see the Config File tab). Editing rules while the config is broken could lose data.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rules are checked top to bottom. Detection rules decide how a window is classified (tile / float / ignore). Callbacks run commands when a window appears.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SettingsSection(title: "Window detection rules") {
                        // DisclosureGroup builds its content lazily (only when expanded), so a long
                        // list of rules renders instantly instead of constructing every Grid/Picker
                        // editor up front
                        ForEach($detectionRules) { $rule in
                            DisclosureGroup {
                                DetectionRuleEditor(rule: $rule)
                                    .onChange(of: rule) { _ in dirty = true }
                            } label: {
                                RuleSummaryRow(text: rule.summary, onDelete: { remove(rule: rule) })
                            }
                            Divider()
                        }
                        Button("Add detection rule") {
                            detectionRules.append(DetectionRuleDraft())
                            dirty = true
                        }
                    }

                    SettingsSection(title: "On window detected callbacks") {
                        ForEach($callbacks) { $callback in
                            DisclosureGroup {
                                CallbackEditor(callback: $callback)
                                    .onChange(of: callback) { _ in dirty = true }
                            } label: {
                                RuleSummaryRow(text: callback.summary, onDelete: { remove(callback: callback) })
                            }
                            Divider()
                        }
                        Button("Add callback") {
                            callbacks.append(CallbackDraft())
                            dirty = true
                        }
                    }

                    HStack {
                        Button("Apply rules") { applyDrafts() }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!dirty)
                        Button("Revert") { loadDrafts() }
                            .disabled(!dirty)
                        if let applyError {
                            Text(applyError).font(.caption).foregroundStyle(.red)
                        } else if dirty {
                            Text("Unapplied changes").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                }
                .padding(16)
            }
            .onAppear(perform: loadDrafts)
        }
    }

    private func remove(rule: DetectionRuleDraft) {
        detectionRules.removeAll { $0.id == rule.id }
        dirty = true
    }

    private func remove(callback: CallbackDraft) {
        callbacks.removeAll { $0.id == callback.id }
        dirty = true
    }

    private func loadDrafts() {
        detectionRules = model.parsedConfig.windowDetectionRules.map(DetectionRuleDraft.init)
        callbacks = model.parsedConfig.onWindowDetected.map(CallbackDraft.init)
        dirty = false
        applyError = nil
    }

    private func applyDrafts() {
        for rule in detectionRules {
            if let err = rule.validationError {
                applyError = err
                return
            }
        }
        for callback in callbacks {
            if let err = callback.validationError {
                applyError = err
                return
            }
        }
        applyError = nil
        model.apply { text in
            var text = TomlPatcher.replaceArrayOfTables(text, name: "window-detection-rules", sections: detectionRules.map { $0.serialize() })
            text = TomlPatcher.replaceArrayOfTables(text, name: "on-window-detected", sections: callbacks.map { $0.serialize() })
            return text
        }
        loadDrafts()
    }
}

// MARK: - Detection rule draft

struct DetectionRuleDraft: Identifiable, Equatable {
    let id = UUID()
    var appId = ""
    var appNameRegex = ""
    var titleRegex = ""
    var windowSubrole = ""
    var windowLevel = "" // '', 'normal', 'always-on-top', or an integer
    var duringStartup = "any" // any | true | false
    var treatAs = "float"

    init() {}

    @MainActor init(_ rule: WindowDetectionRule) {
        appId = rule.matcher.appId ?? ""
        appNameRegex = rule.matcher.appNameRegexSubstring?.origin ?? ""
        titleRegex = rule.matcher.windowTitleRegexSubstring?.origin ?? ""
        windowSubrole = rule.matcher.windowSubrole ?? ""
        windowLevel = switch rule.matcher.windowLevel {
            case nil: ""
            case .normalWindow: "normal"
            case .alwaysOnTopWindow: "always-on-top"
            case .unknown(let level): String(level)
        }
        duringStartup = rule.matcher.duringAeroSpaceStartup.map { $0 ? "true" : "false" } ?? "any"
        treatAs = rule.treatAs.rawValue
    }

    /// Cheap one-line summary for the collapsed row (no regex compilation)
    var summary: String {
        let condition = [
            appId.isEmpty ? nil : appId,
            appNameRegex.isEmpty ? nil : "app~\(appNameRegex)",
            titleRegex.isEmpty ? nil : "title~\(titleRegex)",
            windowSubrole.isEmpty ? nil : "subrole=\(windowSubrole)",
            windowLevel.isEmpty ? nil : "level=\(windowLevel)",
        ].compactMap { $0 }.first ?? "(no condition)"
        return "\(treatAs) · \(condition)"
    }

    var validationError: String? {
        let matcherEmpty = [appId, appNameRegex, titleRegex, windowSubrole, windowLevel].allSatisfy(\.isEmpty) && duringStartup == "any"
        if matcherEmpty { return "A detection rule needs at least one 'if' condition" }
        if !windowLevel.isEmpty, !["normal", "always-on-top"].contains(windowLevel), Int(windowLevel) == nil {
            return "window-level must be 'normal', 'always-on-top', or an integer"
        }
        for (name, pattern) in [("app-name", appNameRegex), ("window-title", titleRegex)] where !pattern.isEmpty {
            if case .failure(let msg) = CaseInsensitiveRegex.new(pattern) { return "\(name) regex: \(msg)" }
        }
        return nil
    }

    func serialize() -> String {
        var lines = ["[[window-detection-rules]]"]
        if !appId.isEmpty { lines.append("if.app-id = \(TomlPatcher.serialize(string: appId))") }
        if !appNameRegex.isEmpty { lines.append("if.app-name-regex-substring = \(TomlPatcher.serialize(string: appNameRegex))") }
        if !titleRegex.isEmpty { lines.append("if.window-title-regex-substring = \(TomlPatcher.serialize(string: titleRegex))") }
        if !windowSubrole.isEmpty { lines.append("if.window-subrole = \(TomlPatcher.serialize(string: windowSubrole))") }
        if !windowLevel.isEmpty {
            lines.append(Int(windowLevel) != nil ? "if.window-level = \(windowLevel)" : "if.window-level = \(TomlPatcher.serialize(string: windowLevel))")
        }
        if duringStartup != "any" { lines.append("if.during-aerospace-startup = \(duringStartup)") }
        lines.append("treat-as = \(TomlPatcher.serialize(string: treatAs))")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Cheap collapsed-row label: a one-line summary + delete, built for every rule.
/// The expensive editor lives in the DisclosureGroup content and is built only on expand
private struct RuleSummaryRow: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.body.monospaced()).lineLimit(1).truncationMode(.tail)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct DetectionRuleEditor: View {
    @Binding var rule: DetectionRuleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Treat as", selection: $rule.treatAs) {
                Text("Tile").tag("tile")
                Text("Float").tag("float")
                Text("Ignore").tag("ignore")
            }
            .frame(width: 180)
            matcherFields
            if let err = rule.validationError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var matcherFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text("App bundle id")
                TextField("com.example.App", text: $rule.appId).font(.body.monospaced())
                Text("App name regex")
                TextField("substring regex", text: $rule.appNameRegex).font(.body.monospaced())
            }
            GridRow {
                Text("Title regex")
                TextField("substring regex", text: $rule.titleRegex).font(.body.monospaced())
                Text("Window subrole")
                TextField("AXStandardWindow", text: $rule.windowSubrole).font(.body.monospaced())
            }
            GridRow {
                Text("Window level")
                TextField("normal / always-on-top / int", text: $rule.windowLevel).font(.body.monospaced())
                Text("During startup")
                Picker("", selection: $rule.duringStartup) {
                    Text("Any").tag("any")
                    Text("Only startup").tag("true")
                    Text("Only after startup").tag("false")
                }
                .labelsHidden()
            }
        }
        .font(.caption)
    }
}

// MARK: - on-window-detected callback draft

struct CallbackDraft: Identifiable, Equatable {
    let id = UUID()
    var matcherKind = "conditions" // conditions | command
    var appId = ""
    var appNameRegex = ""
    var titleRegex = ""
    var workspace = ""
    var duringStartup = "any"
    var matcherCommand = "" // for `if = '<command>'` form
    var checkFurtherCallbacks = false
    var run = ""

    init() {}

    @MainActor init(_ callback: WindowDetectedCallback) {
        switch callback.matcher {
            case .legacy(let legacy):
                matcherKind = "conditions"
                appId = legacy.appId ?? ""
                appNameRegex = legacy.appNameRegexSubstring?.origin ?? ""
                titleRegex = legacy.windowTitleRegexSubstring?.origin ?? ""
                workspace = legacy.workspace ?? ""
                duringStartup = legacy.duringAeroSpaceStartup.map { $0 ? "true" : "false" } ?? "any"
            case .command(let command):
                matcherKind = "command"
                matcherCommand = command.shellOfCommandsDescription
        }
        checkFurtherCallbacks = callback.checkFurtherCallbacks
        run = callback.run.shellOfCommandsDescription
    }

    /// Cheap one-line summary for the collapsed row (no regex compilation)
    var summary: String {
        let condition: String = if matcherKind == "command" {
            matcherCommand.isEmpty ? "(command)" : "if \(matcherCommand)"
        } else {
            [
                appId.isEmpty ? nil : appId,
                appNameRegex.isEmpty ? nil : "app~\(appNameRegex)",
                titleRegex.isEmpty ? nil : "title~\(titleRegex)",
                workspace.isEmpty ? nil : "ws=\(workspace)",
            ].compactMap { $0 }.first ?? "(all windows)"
        }
        let firstRun = run.split(separator: "\n").first.map(String.init) ?? "(no command)"
        return "\(condition) → \(firstRun)"
    }

    var validationError: String? {
        if run.trimmingCharacters(in: .whitespaces).isEmpty { return "'run' command is mandatory" }
        if matcherKind == "command", matcherCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The matcher command is empty. Use 'true' to match all windows"
        }
        for (name, pattern) in [("app-name", appNameRegex), ("window-title", titleRegex)] where !pattern.isEmpty {
            if case .failure(let msg) = CaseInsensitiveRegex.new(pattern) { return "\(name) regex: \(msg)" }
        }
        return nil
    }

    func serialize() -> String {
        var lines = ["[[on-window-detected]]"]
        if matcherKind == "command" {
            lines.append("if = \(TomlPatcher.serialize(string: matcherCommand))")
        } else {
            if !appId.isEmpty { lines.append("if.app-id = \(TomlPatcher.serialize(string: appId))") }
            if !appNameRegex.isEmpty { lines.append("if.app-name-regex-substring = \(TomlPatcher.serialize(string: appNameRegex))") }
            if !titleRegex.isEmpty { lines.append("if.window-title-regex-substring = \(TomlPatcher.serialize(string: titleRegex))") }
            if !workspace.isEmpty { lines.append("if.workspace = \(TomlPatcher.serialize(string: workspace))") }
            if duringStartup != "any" { lines.append("if.during-aerospace-startup = \(duringStartup)") }
        }
        if checkFurtherCallbacks { lines.append("check-further-callbacks = true") }
        let runLines = run.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lines.append(runLines.count == 1
            ? "run = \(TomlPatcher.serialize(string: runLines[0]))"
            : "run = \(TomlPatcher.serialize(stringArray: runLines))")
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct CallbackEditor: View {
    @Binding var callback: CallbackDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Match by", selection: $callback.matcherKind) {
                    Text("Conditions").tag("conditions")
                    Text("Command").tag("command")
                }
                .frame(width: 220)
                Toggle("Check further callbacks", isOn: $callback.checkFurtherCallbacks)
                Spacer()
            }
            if callback.matcherKind == "command" {
                TextField("Matcher command (exit code 0 = match), e.g. true", text: $callback.matcherCommand)
                    .font(.body.monospaced())
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("App bundle id")
                        TextField("com.example.App", text: $callback.appId).font(.body.monospaced())
                        Text("App name regex")
                        TextField("substring regex", text: $callback.appNameRegex).font(.body.monospaced())
                    }
                    GridRow {
                        Text("Title regex")
                        TextField("substring regex", text: $callback.titleRegex).font(.body.monospaced())
                        Text("Workspace")
                        TextField("name", text: $callback.workspace).font(.body.monospaced())
                    }
                    GridRow {
                        Text("During startup")
                        Picker("", selection: $callback.duringStartup) {
                            Text("Any").tag("any")
                            Text("Only startup").tag("true")
                            Text("Only after startup").tag("false")
                        }
                        .labelsHidden()
                        .gridCellColumns(3)
                    }
                }
                .font(.caption)
            }
            TextField("Run command(s), one per line", text: $callback.run, axis: .vertical)
                .font(.body.monospaced())
            if let err = callback.validationError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
