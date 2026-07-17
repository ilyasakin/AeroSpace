import Common
import SwiftUI

/// Full config file editor. The escape hatch that keeps every config capability
/// reachable from the GUI, including things the structured tabs don't model.
struct RawConfigSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel
    @State private var draft: String = ""
    /// The model text the draft was last synced from; lets us tell user edits apart from external changes
    @State private var lastSynced: String = ""
    @State private var diagnostics: [String] = []
    @State private var validated = false

    private var dirty: Bool { draft != model.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 12).monospaced())
                .autocorrectionDisabled()
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            if !diagnostics.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diagnostics.indices, id: \.self) { i in
                            Text(diagnostics[i])
                                .font(.caption.monospaced())
                                .foregroundStyle(diagnostics[i].hasPrefix("[ERROR]") ? .red : .orange)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            } else if validated {
                Label("Config is valid", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            HStack {
                Button("Validate") { validate() }
                Button("Save & Reload") { saveAndReload() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty)
                Button("Revert") {
                    draft = model.text
                    diagnostics = []
                    validated = false
                }
                .disabled(!dirty)
                if dirty {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                openConfigButton()
            }
        }
        .padding(16)
        .onAppear {
            draft = model.text
            lastSynced = model.text
        }
        .onChange(of: model.text) { newText in
            // External change (another tab's edit, or a reload). Only clobber an unedited draft
            if draft == lastSynced || draft.isEmpty {
                draft = newText
            }
            lastSynced = newText
        }
    }

    private func validate() {
        let result = parseConfig(draft)
        diagnostics = result.errors.map { $0.description(.error) } + result.warnings.map { $0.description(.warning) }
        validated = true
    }

    private func saveAndReload() {
        validate()
        // Errors don't block saving: the file editor must stay as capable as an external editor.
        // The reload machinery itself refuses to apply configs with severe errors
        model.save(draft)
    }
}
