import Common
import SwiftUI

/// Multi-line editor for a list of AeroSpace commands, one per line, with command-name completion.
///
/// Binding a TextEditor directly to `ConfigSettingsModel.commandListBinding` is broken: that
/// binding's setter strips empty lines and calls `apply` (which rewrites the file, reloads the
/// live config, and REJECTS anything that doesn't parse) on every keystroke - so pressing Enter,
/// or typing a half-finished command, gets normalized/reverted immediately. This editor keeps a
/// local draft that is edited freely and only committed to the model when the field loses focus.
struct CommandListEditor: View {
    /// The model binding: get() yields the normalized command list, set() commits + reloads
    let text: Binding<String>
    var height: CGFloat = 48

    @State private var draft: String = ""
    /// The model value the draft was last synced from, to tell user edits from external changes
    @State private var lastSynced: String = ""
    @FocusState private var focused: Bool

    /// All AeroSpace subcommand names, the IntelliSense source
    private static let commandNames: [String] = CmdKind.allCases.map(\.rawValue).sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .focused($focused)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? Color.accentColor : Color(.separatorColor)))
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() } // commit once, on blur - not per keystroke
                }
            // Not gated on `focused`: clicking a suggestion blurs the editor, and hiding the list
            // on that blur would swallow the click. The list empties itself once the token is a
            // complete command name
            if !suggestions.isEmpty {
                completionList
            }
        }
        .onAppear {
            draft = text.wrappedValue
            lastSynced = text.wrappedValue
        }
        .onChange(of: text.wrappedValue) { newValue in
            // External change (reload, another tab). Only replace an untouched draft
            if draft == lastSynced {
                draft = newValue
            }
            lastSynced = newValue
        }
    }

    // MARK: Completion

    /// The command token currently being typed: the first word of the last line
    private var currentToken: String {
        let lastLine = draft.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return String(lastLine.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace }))
    }

    private var suggestions: [String] {
        let token = currentToken
        guard token.count >= 1 else { return [] }
        // Don't suggest once the token is already a complete command name
        if Self.commandNames.contains(token) { return [] }
        let lower = token.lowercased()
        let prefix = Self.commandNames.filter { $0.hasPrefix(lower) }
        let contains = Self.commandNames.filter { !$0.hasPrefix(lower) && $0.contains(lower) }
        return Array((prefix + contains).prefix(6))
    }

    @ViewBuilder private var completionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { name in
                Button {
                    complete(with: name)
                } label: {
                    HStack {
                        Text(name).font(.body.monospaced())
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separatorColor)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Replaces the command token on the last line with the chosen command name
    private func complete(with name: String) {
        var lines = draft.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.last else { return }
        let leadingWhitespace = String(last.prefix(while: \.isWhitespace))
        let rest = String(last.drop(while: \.isWhitespace).drop(while: { !$0.isWhitespace })) // args after the command
        lines[lines.count - 1] = leadingWhitespace + name + (rest.isEmpty ? " " : rest)
        draft = lines.joined(separator: "\n")
    }

    private func commit() {
        if draft != lastSynced {
            text.wrappedValue = draft
            lastSynced = text.wrappedValue // read back the normalized value
        }
    }
}
