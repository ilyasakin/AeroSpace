@testable import AppBundle
import Common
import HotKey
import XCTest

/// Bugs found by the architecture audit (step 0 of the re-architecture)
@MainActor
final class AuditStep0Test: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { ServerState.isEnabled = true }

    /// Installed in the main mode: a press runs the CURRENT config's command for its key
    private func binding(_ command: String) -> HotkeyBinding {
        let b = HotkeyBinding(.option, .seven, parseCommand(command).cmdOrDie)
        config.modes[mainModeId] = Mode(bindings: [b.descriptionWithKeyCode: b])
        activeMode = mainModeId
        return b
    }

    /// `enable off` flips the server off, then awaits window restores before the hotkeys go. A
    /// press queued in that gap hit `checkServerIsEnabledOrDie` and crashed the app.
    func testHotkeyPressWhileDisabledIsDroppedNotFatal() async throws {
        ServerState.isEnabled = false
        try await runHotkeyBinding(binding("workspace 7"))
        XCTAssertNotEqual(focus.workspace.name, "7", "a disabled server must not run bindings")

        ServerState.isEnabled = true
        try await runHotkeyBinding(binding("workspace 7"))
        XCTAssertEqual(focus.workspace.name, "7")
    }

    /// Rename moved only focus and the monitor; name-keyed state elsewhere kept the old name
    func testRenameLeavesNoStateUnderTheOldName() {
        let old = Workspace.get(byName: "old")
        let a = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        a.tileRestoreSlot = FloatingRestoreSlot.capture(from: a)
        SpecialWorkspaceToggleState.remember("old", for: "scratch", onMonitor: "main")

        XCTAssertTrue(old.rename(to: "new"))

        XCTAssertTrue(Workspace.get(byName: "old").rootTilingContainer.children.isEmpty, "a reused name must start empty")
        XCTAssertEqual(a.tileRestoreSlot?.workspaceName, "new")
        XCTAssertEqual(SpecialWorkspaceToggleState.remembered(for: "scratch", onMonitor: "main"), "new")
        XCTAssertEqual(Workspace.get(byName: "new").rootTilingContainer.children.count, 2)
    }

    func testRenamingTheSpecialWorkspaceKeepsItsToggleMemory() {
        SpecialWorkspaceToggleState.remember("1", for: "scratch", onMonitor: "main")
        _ = Workspace.get(byName: "scratch").rename(to: "notes")
        XCTAssertEqual(SpecialWorkspaceToggleState.remembered(for: "notes", onMonitor: "main"), "1")
        XCTAssertNil(SpecialWorkspaceToggleState.remembered(for: "scratch", onMonitor: "main"))
    }
}
