@testable import AppBundle
import Common
import Foundation
import HotKey
import XCTest

let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

@MainActor
func setUpWorkspacesForTests() {
    // Every test runs against a fresh simulated desktop behind the macOS port
    MacOS.install(SimulatedMacOS.shared)
    SimulatedMacOS.shared.reset()
    FocusReconciler.resetForTests()
    WindowMemory.resetForTests()
    resetMacosNativeWindowStateCacheForTests()
    staleTitleWindowIds = []
    SessionLayoutStore.resetForTests()
    // A hotplug test may have left extra simulated monitors (and their workspace mapping) behind
    unsafe testMonitorsOverride = nil
    gcMonitors()
    config = defaultConfig
    configUrl = defaultConfigUrl
    config.enableNormalizationFlattenContainers = false // Make layout tests more predictable
    config.enableNormalizationOppositeOrientationForNestedContainers = false // Make layout tests more predictable
    config.defaultRootContainerOrientation = .horizontal // Make default layout predictable
    config.tilingPolicy = .manual // Make insertion behavior predictable (dwindle is the shipped default)

    // Don't create any bindings and workspaces for tests
    config.modes = [mainModeId: Mode(bindings: [:])]
    config.persistentWorkspaces = []

    for workspace in Workspace.all {
        workspace.tilingPolicyOverride = nil // per-workspace state outlives a test otherwise
        for child in workspace.children {
            child.unbindFromParent()
        }
    }
    // Global (workspace-less) containers outlive workspaces; a previous test's windows there would
    // leak into this one
    for child in macosPopupWindowsContainer.children + macosMinimizedWindowsContainer.children {
        child.unbindFromParent()
    }
    check(Workspace.get(byName: "setUpWorkspacesForTests").focusWorkspace())
    Workspace.garbageCollectUnusedWorkspaces()
    check(focus.workspace.isEffectivelyEmpty)
    check(focus.workspace === Workspace.all.singleOrNil(), Workspace.all.map(\.description).joined(separator: ", "))
    check(mainMonitor.setActiveWorkspace(focus.workspace))

    TestApp.shared.focusedWindow = nil
    TestApp.shared.windows = []
    // Registry has process lifetime (like production's allWindowsMap), so a previous test's ids
    // must not stay resolvable for the next one.
    Window.registry.removeAll()
}

extension ParsedCmd {
    var errorOrNil: String? {
        return switch self {
            case .failure(let e): e.msg
            case .cmd, .help: nil
        }
    }

    var cmdOrDie: T { cmdOrNil ?? dieT("\(self)") }
}

func testParseCommandFail(_ command: String, msg expectedMsg: String, exitCode expectedExitCode: Int32, file: StaticString = #filePath, line: UInt = #line) {
    let parsed = parseCommand(command)
    switch parsed {
        case .cmd(let command): XCTFail("\(command) isn't supposed to be parcelable")
        case .help: die() // todo test help
        case .failure(let failure):
            assertEquals(failure, .init(expectedMsg, expectedExitCode), file: file, line: line)
    }
}

extension WorkspaceCmdArgs {
    init(target: WorkspaceTarget, autoBackAndForth: Bool? = nil, wrapAround: Bool? = nil) {
        self = WorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(target)
        self._autoBackAndForth = autoBackAndForth
        self._wrapAround = wrapAround
    }
}

extension MoveNodeToWorkspaceCmdArgs {
    init(target: WorkspaceTarget, wrapAround: Bool? = nil) {
        self = MoveNodeToWorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(target)
        self._wrapAround = wrapAround
    }

    init(workspace: String) {
        self = MoveNodeToWorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(.direct(.parse(workspace).getOrDie()))
    }
}

extension HotkeyBinding {
    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: Shell<any Command>) {
        let descriptionWithKeyNotation = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.init(modifiers, keyCode, commands, descriptionWithKeyNotation: descriptionWithKeyNotation)
    }
}

extension FocusCommand {
    static func new(direction: CardinalDirection) -> FocusCommand {
        FocusCommand(args: FocusCmdArgs(rawArgs: [], cardinalOrDfsDirection: .direction(direction)))
    }
}

func parseCommand(_ raw: String) -> ParsedCmd<Shell<any Command>> { parseCommand(raw, allowExecAndForget: true, allowEval: true) }
