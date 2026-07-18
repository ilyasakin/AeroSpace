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
                    }

                    SettingsSection(title: "Workspaces module") {
                        Toggle(
                            "Hide unoccupied workspaces",
                            isOn: model.boolBinding(["bar"], "hide-empty-workspaces", get: \.statusBar.hideEmptyWorkspaces),
                        )
                        Text("When on, only workspaces with windows are listed (the focused workspace always stays visible).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSection(title: "Left modules") {
                        Text("Toggle to show on the bar. Drag the grip on “On bar” rows to reorder (left → right).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BarModulePicker(
                            selected: modules(for: "modules-left", fallback: \.statusBar.modulesLeft),
                            onChange: { model.setStringArray(["bar"], "modules-left", $0) },
                        )
                    }

                    SettingsSection(title: "Right modules") {
                        Text("Toggle to show on the bar. Drag the grip on “On bar” rows to reorder (left → right).")
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

/// One switch per module (on/off). Drag the grip on “On bar” rows to reorder.
///
/// macOS has no `EditMode`, so reordering uses explicit drag-and-drop (not List.onMove).
struct BarModulePicker: View {
    let selected: [String]
    let onChange: ([String]) -> Void

    private var catalog: [StatusBarBuiltinModule] { StatusBarBuiltinModule.allCases }
    private var available: [StatusBarBuiltinModule] {
        catalog.filter { !selected.contains($0.rawValue) }
    }

    @State private var draggingId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On bar")
                .font(.subheadline.weight(.semibold))
            if selected.isEmpty {
                Text("Nothing on this side yet — turn a module on below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                        moduleRow(
                            id: id,
                            isOn: true,
                            showGrip: true,
                            isDropTarget: draggingId != nil && draggingId != id,
                        ) {
                            onChange(selected.filter { $0 != id })
                        }
                        .onDrag {
                            draggingId = id
                            return NSItemProvider(object: id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: BarModuleReorderDropDelegate(
                                itemId: id,
                                selected: selected,
                                draggingId: $draggingId,
                                onChange: onChange,
                            ),
                        )
                        if index < selected.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }

            if !available.isEmpty {
                Text("Available")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(available.enumerated()), id: \.element.rawValue) { index, mod in
                        moduleRow(id: mod.rawValue, isOn: false, showGrip: false, isDropTarget: false) {
                            onChange(selected + [mod.rawValue])
                        }
                        if index < available.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }

    @ViewBuilder
    private func moduleRow(
        id: String,
        isOn: Bool,
        showGrip: Bool,
        isDropTarget: Bool,
        flip: @escaping () -> Void,
    ) -> some View {
        HStack(spacing: 10) {
            if showGrip {
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help("Drag to reorder")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(StatusBarBuiltinModule(rawValue: id)?.title ?? id)
                    .font(.body)
                Text(id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Single on/off control — no extra checkmark icon.
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        if newValue != isOn { flip() }
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
    }
}

/// Drop onto a selected row → move the dragged module to that row’s index.
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
