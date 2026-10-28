@testable import AppBundle
import Common
import XCTest

/// Step 7: the side UI (borders, group tab bar, status bar, tray) is a projection of the model. It
/// draws; it never changes the model. A click runs a command in a session, like a hotkey.
@MainActor
final class UiProjectionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Kernel.resetViolationsForTests()
    }

    func testDrawingTheUiChangesNothing() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        try await HeadlessHarness.run(["layout accordion", "focus parent", "workspace 2", "workspace 1"])
        Kernel.resetViolationsForTests()

        await Kernel.exclusive("test: draw") {
            WindowBordersManager.shared.refresh()
            WindowBordersManager.shared.syncActiveFocus()
            GroupTabBarManager.shared.refresh()
            StatusBarManager.shared.refresh()
            updateTrayText()
        }
        XCTAssertEqual(Kernel.violations, [], "UI drawing changed the model")
    }

    func testAMutationWhileDrawingIsCaught() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        Kernel.resetViolationsForTests()
        await Kernel.exclusive("test: bad draw") {
            Kernel.enterProjection()
            window.desiredRect = nil
            Kernel.exitProjection()
        }
        XCTAssertEqual(Kernel.violations, ["desiredRect (while drawing UI)"])
    }

    /// UI code may not reach for the model's mutators; clicks go through `runUiCommand`
    func testUiCodeHasNoMutators() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle/ui")
        let mutators = ["focusWindow(", "focusWorkspace(", ".bind(to:", "unbindFromParent(", "setWeight(", "setLayout(",
                        "changeOrientation(", "desiredRect =", "ServerState.isEnabled =", "runLightSession(", "setFocus("]
        for file in FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
            where file.pathExtension == "swift" && file.lastPathComponent != "uiCommand.swift"
        {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
                .joined(separator: "\n")
            for mutator in mutators where code.contains(mutator) {
                XCTFail("ui/\(file.lastPathComponent) calls `\(mutator)` — UI draws the model; a click is `runUiCommand([...])`")
            }
        }
    }
}
