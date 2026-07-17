import Common
import SwiftUI

struct KeybindingsSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel
    @State private var selectedMode = mainModeId
    @State private var newCombo = ""
    @State private var newCommand = ""
    @State private var newModeName = ""
    @State private var addError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(modeNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                Spacer()
                TextField("New mode", text: $newModeName)
                    .frame(width: 120)
                Button("Add mode") {
                    let name = newModeName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !modeNames.contains(name) else { return }
                    // A fresh mode needs at least one binding to be useful; esc -> back to main is the convention
                    model.apply { TomlPatcher.setValue($0, table: ["mode", name, "binding"], key: "esc", rawValue: "'mode \(mainModeId)'") }
                    newModeName = ""
                    selectedMode = name
                }
                .disabled(newModeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .top], 16)

            List {
                ForEach(bindings, id: \.key) { binding in
                    BindingRow(
                        combo: binding.key,
                        command: displayCommand(binding.rawValue),
                        validate: validate,
                        onCommit: { combo, command in commitEdit(oldCombo: binding.key, combo: combo, command: command) },
                        onDelete: { model.apply { TomlPatcher.removeKey($0, table: bindingTable, key: binding.key) } },
                    )
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Key combo (e.g. alt-shift-h)", text: $newCombo)
                                .frame(width: 220)
                                .font(.body.monospaced())
                            TextField("Command (e.g. focus left). Separate multiple with newlines", text: $newCommand)
                                .font(.body.monospaced())
                            Button("Add") { addBinding() }
                                .disabled(newCombo.isEmpty || newCommand.isEmpty)
                        }
                        if let addError {
                            Text(addError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            Text("Key notation reference: modifiers alt/cmd/ctrl/shift joined with '-', e.g. alt-shift-enter. See the guide for the full list of keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 16)
        }
        .onChange(of: modeNames) { names in
            if !names.contains(selectedMode) { selectedMode = names.first ?? mainModeId }
        }
    }

    private var bindingTable: [String] { ["mode", selectedMode, "binding"] }

    private var modeNames: [String] {
        let names = model.parsedConfig.modes.keys.sorted()
        return names.contains(mainModeId) ? [mainModeId] + names.filter { $0 != mainModeId } : names
    }

    private var bindings: [(key: String, rawValue: String)] {
        TomlPatcher.keys(model.text, table: bindingTable)
    }

    private func displayCommand(_ rawValue: String) -> String {
        parseTomlStringOrStringArray(rawValue).joined(separator: "\n")
    }

    /// nil if valid, otherwise a message. Combo syntax is validated against the config's key mapping;
    /// each command line must parse as a config command
    @MainActor
    private func validate(combo: String, command: String) -> String? {
        if case .failure(let err) = parseBinding(combo, .rootKey("gui"), model.parsedConfig.keyMapping.resolve()) {
            return err.message
        }
        for line in commandLines(command) {
            if case .failure(let msg) = parseCommand(line, allowExecAndForget: true, allowEval: false).toResult() {
                return msg
            }
        }
        return nil
    }

    private func commandLines(_ command: String) -> [String] {
        command.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func serializeCommand(_ command: String) -> String {
        let lines = commandLines(command)
        return lines.count == 1 ? TomlPatcher.serialize(string: lines[0]) : TomlPatcher.serialize(stringArray: lines)
    }

    private func commitEdit(oldCombo: String, combo: String, command: String) {
        model.apply { text in
            var text = text
            if oldCombo != combo {
                text = TomlPatcher.removeKey(text, table: bindingTable, key: oldCombo)
            }
            return TomlPatcher.setValue(text, table: bindingTable, key: combo, rawValue: serializeCommand(command))
        }
    }

    private func addBinding() {
        if let error = validate(combo: newCombo, command: newCommand) {
            addError = error
            return
        }
        addError = nil
        model.apply { TomlPatcher.setValue($0, table: bindingTable, key: newCombo.trimmingCharacters(in: .whitespaces), rawValue: serializeCommand(newCommand)) }
        newCombo = ""
        newCommand = ""
    }
}

private struct BindingRow: View {
    let combo: String
    let command: String
    let validate: @MainActor (String, String) -> String?
    let onCommit: (String, String) -> Void
    let onDelete: () -> Void

    @State private var comboDraft = ""
    @State private var commandDraft = ""
    @State private var error: String? = nil
    @FocusState private var focusedField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("", text: $comboDraft)
                    .frame(width: 220)
                    .font(.body.monospaced())
                    .focused($focusedField)
                    .onSubmit(commit)
                TextField("", text: $commandDraft, axis: .vertical)
                    .font(.body.monospaced())
                    .focused($focusedField)
                    .onSubmit(commit)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { reset() }
        .onChange(of: combo) { _ in reset() }
        .onChange(of: command) { _ in reset() }
        .onChange(of: focusedField) { isFocused in
            if !isFocused, comboDraft != combo || commandDraft != command { commit() }
        }
    }

    private func reset() {
        comboDraft = combo
        commandDraft = command
        error = nil
    }

    private func commit() {
        guard comboDraft != combo || commandDraft != command else { return }
        if let validationError = validate(comboDraft, commandDraft) {
            error = validationError
            return
        }
        error = nil
        onCommit(comboDraft.trimmingCharacters(in: .whitespaces), commandDraft)
    }
}
