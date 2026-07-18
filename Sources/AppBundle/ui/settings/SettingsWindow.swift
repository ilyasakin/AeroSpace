import Common
import SwiftUI

public let settingsWindowId = "\(aeroSpaceAppName).settings"

@MainActor
public func getSettingsWindow() -> some Scene {
    SwiftUI.Window("\(aeroSpaceAppName) Settings", id: settingsWindowId) {
        SettingsView()
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
    .windowResizability(.contentSize)
}

struct SettingsView: View {
    @StateObject private var model = ConfigSettingsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab().tabItem { Label("General", systemImage: "gearshape") }
                BarSettingsTab().tabItem { Label("Status Bar", systemImage: "menubar.rectangle") }
                LayoutSettingsTab().tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }
                WorkspacesSettingsTab().tabItem { Label("Workspaces", systemImage: "square.grid.2x2") }
                KeybindingsSettingsTab().tabItem { Label("Keybindings", systemImage: "keyboard") }
                RulesSettingsTab().tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
                RawConfigSettingsTab().tabItem { Label("Config File", systemImage: "doc.text") }
            }
            .environmentObject(model)
            statusBar
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 560, idealHeight: 620)
        .onAppear { model.load() }
    }

    @ViewBuilder private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastError = model.lastError {
                Label(lastError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            if !model.errors.isEmpty {
                Label("\(model.errors.count) config error(s) — see the Config File tab", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if !model.warnings.isEmpty {
                Label("\(model.warnings.count) config warning(s) — see the Config File tab", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(model.configPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Reveal in Finder") {
                    if let url = model.editedUrl {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// A labeled section with the standard macOS settings look
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection(title: "Startup") {
                    Toggle("Start AeroSpace at login", isOn: model.boolBinding([], "start-at-login", get: \.startAtLogin))
                    Toggle("Reload config when the file changes", isOn: model.boolBinding([], "auto-reload-config", get: \.autoReloadConfig))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Commands to run after startup (one per line)")
                        CommandListEditor(text: model.commandListBinding("after-startup-command"))
                    }
                }
                SettingsSection(title: "Focus") {
                    Toggle("Focus follows mouse", isOn: model.boolBinding(["focus-follows-mouse"], "enabled", get: \.focusFollowsMouse.enabled))
                    Toggle(
                        "Automatically unhide hidden apps (disable ⌘H hiding)",
                        isOn: model.boolBinding([], "automatically-unhide-macos-hidden-apps", get: \.automaticallyUnhideMacosHiddenApps),
                    )
                }
                SettingsSection(title: "Key mapping") {
                    Picker("Keyboard layout preset", selection: model.stringChoiceBinding(["key-mapping"], "preset", get: { _ in currentKeyMappingPreset() })) {
                        Text("QWERTY").tag("qwerty")
                        Text("Dvorak").tag("dvorak")
                        Text("Colemak").tag("colemak")
                    }
                    .pickerStyle(.segmented)
                }
                SettingsSection(title: "Callbacks (one command per line)") {
                    callbackEditor("On focus changed", key: "on-focus-changed")
                    callbackEditor("On focused monitor changed", key: "on-focused-monitor-changed")
                    callbackEditor("On mode changed", key: "on-mode-changed")
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func callbackEditor(_ title: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            CommandListEditor(text: model.commandListBinding(key), height: 40)
        }
    }
}

// MARK: - Status Bar tab

struct BarSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection(title: "Status bar") {
                    Toggle("Show status bar", isOn: model.boolBinding(["bar"], "enabled", get: \.statusBar.enabled))
                    Text("Sits below the macOS menu bar on each monitor. Not a menu-bar replacement. Linux bars (polybar/i3status) do not run on macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.parsedConfig.statusBar.enabled || barEnabledInFile {
                    SettingsSection(title: "Size") {
                        HStack {
                            Text("Height")
                            Spacer()
                            IntField(value: model.intBinding(["bar"], "height", get: \.statusBar.height))
                        }
                        HStack {
                            Text("Font size")
                            Spacer()
                            IntField(value: model.intBinding(["bar"], "font-size", get: \.statusBar.fontSize))
                        }
                        HStack {
                            Text("Clock format")
                            Spacer()
                            TextField(
                                "%H:%M",
                                text: model.stringChoiceBinding(["bar"], "clock-format", get: \.statusBar.clockFormat),
                            )
                            .frame(width: 140)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                        }
                        Text("strftime-style: %H %M %S %d %m %Y %y  (e.g. %d/%m %H:%M)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSection(title: "Workspaces module") {
                        Toggle(
                            "Hide unoccupied workspaces",
                            isOn: model.boolBinding(["bar"], "hide-empty-workspaces", get: \.statusBar.hideEmptyWorkspaces),
                        )
                        Text("When on, only workspaces with windows are listed (the focused workspace always stays visible).")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 4)

                        Text("Workspace symbols")
                            .font(.subheadline.weight(.semibold))
                        Text("Optional letter, emoji, or short label shown on the bar instead of the workspace name. Clicks still target the real workspace.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        WorkspaceSymbolsEditor()
                    }

                    SettingsSection(title: "Focused app module") {
                        Toggle(
                            "Show app icon",
                            isOn: model.boolBinding(["bar"], "focused-show-icon", get: \.statusBar.focusedShowIcon),
                        )
                        Text("Draws the current app’s Dock icon next to its name in the “focused” module.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSection(title: "Left modules") {
                        Text("Switch on to show. Drag the grip to reorder left → right.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BarModulePicker(
                            selected: modules(for: "modules-left", fallback: \.statusBar.modulesLeft),
                            onChange: { model.setStringArray(["bar"], "modules-left", $0) },
                        )
                    }

                    SettingsSection(title: "Right modules") {
                        Text("Switch on to show. Drag the grip to reorder left → right.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BarModulePicker(
                            selected: modules(for: "modules-right", fallback: \.statusBar.modulesRight),
                            onChange: { model.setStringArray(["bar"], "modules-right", $0) },
                        )
                    }

                    SettingsSection(title: "External status command (optional)") {
                        Text("argv of an i3bar-protocol process — one argument per line (executable first).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        CommandListEditor(
                            text: model.stringArrayBinding(["bar"], "status-command", get: \.statusBar.statusCommand),
                            height: 48,
                            suggestCommands: false,
                        )
                    }

                    SettingsSection(title: "Colors") {
                        colorField("Background", key: "background", get: \.statusBar.background)
                        colorField("Foreground", key: "foreground", get: \.statusBar.foreground)
                        colorField("Focused background", key: "focused-background", get: \.statusBar.focusedBackground)
                        colorField("Focused foreground", key: "focused-foreground", get: \.statusBar.focusedForeground)
                    }
                }
            }
            .padding(16)
        }
    }

    /// True when the Settings TOML already has `bar.enabled = true` (covers the frame before reparse).
    private var barEnabledInFile: Bool {
        if let raw = TomlPatcher.getRawValue(model.text, table: ["bar"], key: "enabled") {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        return model.parsedConfig.statusBar.enabled
    }

    private func modules(for key: String, fallback: (Config) -> [String]) -> [String] {
        if let raw = TomlPatcher.getRawValue(model.text, table: ["bar"], key: key) {
            return parseTomlStringOrStringArray(raw)
        }
        return fallback(model.parsedConfig)
    }

    @ViewBuilder private func colorField(_ title: String, key: String, get: @escaping (Config) -> String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(
                "#rrggbb",
                text: model.stringChoiceBinding(["bar"], key, get: get),
            )
            .frame(width: 100)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
        }
    }
}

/// Edit `[bar.workspace-symbols]` — workspace name → bar label.
private struct WorkspaceSymbolsEditor: View {
    @EnvironmentObject var model: ConfigSettingsModel
    @State private var newWorkspace = ""
    @State private var newSymbol = ""

    private let table = ["bar", "workspace-symbols"]

    private var rows: [(key: String, rawValue: String)] {
        TomlPatcher.keys(model.text, table: table)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.key) { row in
                WorkspaceSymbolRow(
                    workspace: row.key,
                    symbol: parseTomlStringOrStringArray(row.rawValue).first ?? row.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")),
                    onCommit: { setSymbol(workspace: row.key, symbol: $0) },
                    onDelete: {
                        model.apply { TomlPatcher.removeKey($0, table: table, key: row.key) }
                    },
                )
            }
            HStack {
                TextField("Workspace", text: $newWorkspace)
                    .frame(width: 120)
                TextField("Symbol / label", text: $newSymbol)
                Button("Add") {
                    let ws = newWorkspace.trimmingCharacters(in: .whitespaces)
                    let sym = newSymbol.trimmingCharacters(in: .whitespaces)
                    guard !ws.isEmpty, !sym.isEmpty else { return }
                    setSymbol(workspace: ws, symbol: sym)
                    newWorkspace = ""
                    newSymbol = ""
                }
                .disabled(
                    newWorkspace.trimmingCharacters(in: .whitespaces).isEmpty
                        || newSymbol.trimmingCharacters(in: .whitespaces).isEmpty,
                )
            }
        }
    }

    private func setSymbol(workspace: String, symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        model.apply {
            if trimmed.isEmpty {
                TomlPatcher.removeKey($0, table: table, key: workspace)
            } else {
                TomlPatcher.setValue($0, table: table, key: workspace, rawValue: TomlPatcher.serialize(string: trimmed))
            }
        }
    }
}

private struct WorkspaceSymbolRow: View {
    let workspace: String
    let symbol: String
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(workspace)
                .font(.body.monospaced())
                .frame(width: 120, alignment: .leading)
            TextField("e.g. 一 / 🌐 / W", text: $draft)
                .onSubmit { onCommit(draft) }
                .focused($focused)
                .onChange(of: focused) { isFocused in
                    if !isFocused, draft != symbol { onCommit(draft) }
                }
            Text(draft.isEmpty ? workspace : draft)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .center)
                .help("Preview on the bar")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { draft = symbol }
        .onChange(of: symbol) { draft = $0 }
    }
}

/// Single module list: switch = on the bar, grip = reorder (only while on).
/// One list — no separate “On bar” / “Available” sections (the switch already means that).
///
/// macOS has no `EditMode`, so reordering uses explicit drag-and-drop (not List.onMove).
struct BarModulePicker: View {
    let selected: [String]
    let onChange: ([String]) -> Void

    /// On modules first (in bar order), then off modules in catalog order.
    private var rows: [(id: String, isOn: Bool)] {
        let on = selected.map { (id: $0, isOn: true) }
        let off = StatusBarBuiltinModule.allCases
            .map(\.rawValue)
            .filter { !selected.contains($0) }
            .map { (id: $0, isOn: false) }
        return on + off
    }

    @State private var draggingId: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row)
                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private func rowView(_ row: (id: String, isOn: Bool)) -> some View {
        let base = moduleRow(
            id: row.id,
            isOn: row.isOn,
            isDropTarget: row.isOn && draggingId != nil && draggingId != row.id,
        )
        if row.isOn {
            base
                .onDrag {
                    draggingId = row.id
                    return NSItemProvider(object: row.id as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: BarModuleReorderDropDelegate(
                        itemId: row.id,
                        selected: selected,
                        draggingId: $draggingId,
                        onChange: onChange,
                    ),
                )
        } else {
            base
        }
    }

    @ViewBuilder
    private func moduleRow(
        id: String,
        isOn: Bool,
        isDropTarget: Bool,
    ) -> some View {
        HStack(spacing: 10) {
            // Keep a fixed width so on/off rows share the same column alignment.
            Group {
                if isOn {
                    Image(systemName: "line.3.horizontal")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .help("Drag to reorder")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(StatusBarBuiltinModule(rawValue: id)?.title ?? id)
                    .font(.body)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Text(id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        if newValue == isOn { return }
                        if newValue {
                            onChange(selected + [id])
                        } else {
                            onChange(selected.filter { $0 != id })
                        }
                    },
                ),
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .opacity(isOn ? 1 : 0.85)
    }
}

/// Drop onto an on-bar row → move the dragged module to that row’s index.
private struct BarModuleReorderDropDelegate: DropDelegate {
    let itemId: String
    let selected: [String]
    @Binding var draggingId: String?
    let onChange: ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingId != nil }

    func dropEntered(info: DropInfo) {
        guard let draggingId, draggingId != itemId,
              let from = selected.firstIndex(of: draggingId),
              let to = selected.firstIndex(of: itemId),
              from != to
        else { return }
        var next = selected
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        onChange(next)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// The parsed Config hides the raw preset behind resolve(); read it from the file text instead
@MainActor
private func currentKeyMappingPreset() -> String {
    let raw = TomlPatcher.getRawValue(ConfigSettingsModel.shared.text, table: ["key-mapping"], key: "preset") ?? "'qwerty'"
    return parseTomlStringOrStringArray(raw).first ?? "qwerty"
}

struct LayoutSettingsTab: View {
    @EnvironmentObject var model: ConfigSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection(title: "Defaults") {
                    Picker("Default layout for new workspaces", selection: model.stringChoiceBinding([], "default-root-container-layout", get: { $0.defaultRootContainerLayout == .tiles ? "tiles" : "accordion" })) {
                        Text("Tiles").tag("tiles")
                        Text("Accordion").tag("accordion")
                    }
                    Picker("Default orientation", selection: model.stringChoiceBinding([], "default-root-container-orientation", get: { $0.defaultRootContainerOrientation.rawValue })) {
                        Text("Auto (by monitor shape)").tag("auto")
                        Text("Horizontal").tag("horizontal")
                        Text("Vertical").tag("vertical")
                    }
                    HStack {
                        Text("Accordion padding")
                        Spacer()
                        IntField(value: model.intBinding([], "accordion-padding", get: \.accordionPadding))
                    }
                }
                SettingsSection(title: "Normalization") {
                    Toggle("Flatten nested containers", isOn: model.boolBinding([], "enable-normalization-flatten-containers", get: \.enableNormalizationFlattenContainers))
                    Toggle(
                        "Opposite orientation for nested containers",
                        isOn: model.boolBinding([], "enable-normalization-opposite-orientation-for-nested-containers", get: \.enableNormalizationOppositeOrientationForNestedContainers),
                    )
                }
                SettingsSection(title: "Gaps") {
                    if gapsArePerMonitor {
                        Label(
                            "This config uses per-monitor gap values, which the GUI can't edit. Use the Config File tab.",
                            systemImage: "info.circle",
                        ).foregroundStyle(.secondary)
                    } else {
                        gapField("Inner horizontal", ["gaps", "inner"], "horizontal") { $0.gaps.inner.horizontal }
                        gapField("Inner vertical", ["gaps", "inner"], "vertical") { $0.gaps.inner.vertical }
                        Divider()
                        gapField("Outer left", ["gaps", "outer"], "left") { $0.gaps.outer.left }
                        gapField("Outer right", ["gaps", "outer"], "right") { $0.gaps.outer.right }
                        gapField("Outer top", ["gaps", "outer"], "top") { $0.gaps.outer.top }
                        gapField("Outer bottom", ["gaps", "outer"], "bottom") { $0.gaps.outer.bottom }
                    }
                }
            }
            .padding(16)
        }
    }

    private var gapsArePerMonitor: Bool {
        let gaps = model.parsedConfig.gaps
        let all: [DynamicConfigValue<Int>] = [gaps.inner.horizontal, gaps.inner.vertical, gaps.outer.left, gaps.outer.right, gaps.outer.top, gaps.outer.bottom]
        return all.contains { value in
            if case .constant = value { return false } else { return true }
        }
    }

    @ViewBuilder private func gapField(_ title: String, _ table: [String], _ key: String, _ get: @escaping (Config) -> DynamicConfigValue<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            IntField(value: model.intBinding(table, key, get: { config in
                if case .constant(let v) = get(config) { return v } else { return 0 }
            }))
        }
    }
}

/// A compact integer field with a stepper that commits on edit end
struct IntField: View {
    @Binding var value: Int
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() }
                }
            Stepper("") {
                value += 1
                draft = String(value)
            } onDecrement: {
                value -= 1
                draft = String(value)
            }
            .labelsHidden()
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { newValue in
            if draft != String(newValue) { draft = String(newValue) }
        }
    }

    private func commit() {
        if let parsed = Int(draft.trimmingCharacters(in: .whitespaces)), parsed != value {
            value = parsed
        } else {
            draft = String(value)
        }
    }
}
