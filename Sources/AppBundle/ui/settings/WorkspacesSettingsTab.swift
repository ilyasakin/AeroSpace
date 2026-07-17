import Common
import SwiftUI

struct WorkspacesSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel
    @State private var newWorkspace = ""
    @State private var newAssignmentWorkspace = ""
    @State private var newAssignmentMonitor = ""

    private let assignmentTable = ["workspace-to-monitor-force-assignment"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection(title: "Persistent workspaces") {
                    if model.parsedConfig.configVersion < ._2 {
                        Label(
                            "persistent-workspaces requires 'config-version = 2'. With config-version 1, workspaces are inferred from keybindings.",
                            systemImage: "info.circle",
                        ).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.parsedConfig.persistentWorkspaces), id: \.self) { name in
                            HStack {
                                Text(name).font(.body.monospaced())
                                Spacer()
                                Button(role: .destructive) {
                                    setPersistentWorkspaces(Array(model.parsedConfig.persistentWorkspaces).filter { $0 != name })
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("New workspace name", text: $newWorkspace)
                                .onSubmit(addPersistentWorkspace)
                            Button("Add", action: addPersistentWorkspace)
                                .disabled(newWorkspace.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                SettingsSection(title: "Workspace to monitor assignment") {
                    Text("Monitor patterns: 'main', 'secondary', a 1-based index, or a regex matching the monitor name. Separate fallbacks with commas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let assignments = TomlPatcher.keys(model.text, table: assignmentTable)
                    ForEach(assignments, id: \.key) { assignment in
                        AssignmentRow(
                            workspace: assignment.key,
                            patterns: parseTomlStringOrStringArray(assignment.rawValue).joined(separator: ", "),
                            onCommit: { patterns in setAssignment(workspace: assignment.key, patterns: patterns) },
                            onDelete: { model.apply { TomlPatcher.removeKey($0, table: assignmentTable, key: assignment.key) } },
                        )
                    }
                    HStack {
                        TextField("Workspace", text: $newAssignmentWorkspace)
                            .frame(width: 140)
                        TextField("Monitor pattern(s)", text: $newAssignmentMonitor)
                        Button("Add") {
                            let workspace = newAssignmentWorkspace.trimmingCharacters(in: .whitespaces)
                            setAssignment(workspace: workspace, patterns: newAssignmentMonitor)
                            newAssignmentWorkspace = ""
                            newAssignmentMonitor = ""
                        }
                        .disabled(newAssignmentWorkspace.trimmingCharacters(in: .whitespaces).isEmpty ||
                            newAssignmentMonitor.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(16)
        }
    }

    private func addPersistentWorkspace() {
        let name = newWorkspace.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        setPersistentWorkspaces(Array(model.parsedConfig.persistentWorkspaces) + [name])
        newWorkspace = ""
    }

    private func setPersistentWorkspaces(_ names: [String]) {
        model.apply {
            names.isEmpty
                ? TomlPatcher.removeKey($0, table: [], key: "persistent-workspaces")
                : TomlPatcher.setValue($0, table: [], key: "persistent-workspaces", rawValue: TomlPatcher.serialize(stringArray: names))
        }
    }

    private func setAssignment(workspace: String, patterns: String) {
        let list = patterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        let rawValue = list.count == 1 ? TomlPatcher.serialize(string: list[0]) : TomlPatcher.serialize(stringArray: list)
        model.apply { TomlPatcher.setValue($0, table: assignmentTable, key: workspace, rawValue: rawValue) }
    }
}

private struct AssignmentRow: View {
    let workspace: String
    let patterns: String
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(workspace)
                .font(.body.monospaced())
                .frame(width: 140, alignment: .leading)
            TextField("", text: $draft)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onChange(of: focused) { isFocused in
                    if !isFocused, draft != patterns { onCommit(draft) }
                }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { draft = patterns }
        .onChange(of: patterns) { draft = $0 }
    }
}
