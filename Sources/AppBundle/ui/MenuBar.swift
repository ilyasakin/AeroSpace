import Common
import Foundation
import SwiftUI

@MainActor
public func menuBar(viewModel: TrayMenuModel) -> some Scene { // todo should it be converted to "SwiftUI struct"?
    MenuBarExtra {
        let shortIdentification = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitShortHash)"
        let identification      = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitHash)"
        Text(shortIdentification)
        Button("Copy to clipboard") { identification.copyToClipboard() }
            .keyboardShortcut("C", modifiers: .command)
        Divider()

        if viewModel.axPermissionStatus == .granted {
            if viewModel.isEnabled, viewModel.lastReloadConfigContainedWarnings {
                Button {
                    runUiCommand(["reload-config", "--warnings-as-errors"])
                } label: {
                    Label("Config contains warnings...", systemImage: "exclamationmark.triangle.fill")
                }
                Divider()
            }
            if viewModel.isEnabled {
                Text("Workspaces:")
                ForEach(viewModel.workspaces, id: \.name) { workspace in
                    Button {
                        runUiCommand(["workspace", workspace.name])
                    } label: {
                        Toggle(isOn: .constant(workspace.isFocused)) {
                            Text(workspace.name + workspace.suffix).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                Divider()
            }
            Button {
                SystemServices.open(URL(string: "https://github.com/sponsors/nikitabobko").orDie())
                viewModel.sponsorshipMessage = sponsorshipPrompts.randomElement().orDie()
            } label: {
                Text("Sponsor AeroSpace on GitHub")
                Text(viewModel.sponsorshipMessage)
            }
            Divider()
            Button(viewModel.isEnabled ? "Disable" : "Enable") {
                runUiCommand(["enable", "toggle"])
            }.keyboardShortcut("E", modifiers: .command)
            getExperimentalUISettingsMenu(viewModel: viewModel)
            SettingsButton()
            openConfigButton()
            reloadConfigButton(warningsAsErrors: false)
        } else {
            Button("AeroSpace requires accessibility permission to move windows") {
                viewModel.axPermissionStatus = .waitingWithPrompt
            }
        }
        Button("Quit \(aeroSpaceAppName)") {
            Task.startUnstructured {
                terminationHandler?.beforeTermination()
                terminateApp()
            }
        }.keyboardShortcut("Q", modifiers: .command)
    } label: {
        switch (viewModel.axPermissionStatus, viewModel.isEnabled) {
            case (.granted, true):
                MenuBarLabel().environmentObject(viewModel)
            case (.granted, false):
                Image(systemName: "pause.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case (_, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
        }
    }
}

struct SettingsButton: View {
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    var body: some View {
        Button("Settings…") {
            openWindow(id: settingsWindowId)
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",", modifiers: .command)
    }
}

@MainActor @ViewBuilder
func openConfigButton(showShortcutGroup: Bool = false) -> some View {
    let editor = getTextEditorToOpenConfig()
    let button = Button("Open config in '\(editor.lastPathComponent)'") {
        let fallbackConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
        switch findCustomConfigUrl() {
            case .file(let url):
                url.open(with: editor)
            case .noCustomConfigExists:
                _ = try? FileManager.default.copyItem(atPath: defaultConfigUrl.path, toPath: fallbackConfig.path)
                fallbackConfig.open(with: editor)
            case .ambiguousConfigError:
                fallbackConfig.open(with: editor)
        }
    }.keyboardShortcut(",", modifiers: [.command, .shift])
    switch showShortcutGroup {
        case true: shortcutGroup(label: Text("⌘ ⇧ ,"), content: button)
        case false: button
    }
}

@MainActor @ViewBuilder
func reloadConfigButton(showShortcutGroup: Bool = false, warningsAsErrors: Bool) -> some View {
    if ServerState.isEnabled {
        let button = Button("Reload config") {
            runUiCommand(warningsAsErrors ? ["reload-config", "--warnings-as-errors"] : ["reload-config"])
        }.keyboardShortcut("R", modifiers: .command)
        switch showShortcutGroup {
            case true: shortcutGroup(label: Text("⌘ R"), content: button)
            case false: button
        }
    }
}

func shortcutGroup(label: some View, content: some View) -> some View {
    GroupBox {
        VStack(alignment: .trailing, spacing: 6) {
            label
                .foregroundStyle(Color.secondary)
            content
        }
    }
}

func getTextEditorToOpenConfig() -> URL {
    SystemServices.applicationToOpen(findCustomConfigUrl().urlOrNil ?? defaultConfigUrl)?
        .takeIf { $0.lastPathComponent != "Xcode.app" } // Blacklist Xcode. It is too heavy to open plain text files
        ?? URL(filePath: "/System/Applications/TextEdit.app")
}
