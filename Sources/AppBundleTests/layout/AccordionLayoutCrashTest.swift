@testable import AppBundle
import Common
import XCTest

/// Regression: `layout accordion` used to kill the app — `applyWeightsFromSpine` called
/// `setWeight` on accordion children and `TreeNode.setWeight` fatally die()s for non-tiles/master
/// parents. No test exercised a FULL layout pass over an accordion until this one.
@MainActor
final class AccordionLayoutCrashTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFullLayoutPassOverAccordionDoesNotCrash() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        // Mutate live layout the way LayoutCommand does
        workspace.rootTilingContainer.setLayout(.accordion)

        // The crash fired on the next layout tick — run a real layout pass
        try await workspace.layoutWorkspace()

        // Still alive, and the tree reflects the accordion
        guard case .container(_, let layout, _, _, _) = workspace.currentTilingSpine() else {
            XCTFail("the root is a container")
            return
        }
        XCTAssertEqual(layout, .accordion)
    }

    /// A CONTAINER child of an accordion also reaches setWeight's die(). The window-leaf case was
    /// guarded first; this shape is produced by `join-with` / `split` / `toggle-group` inside an
    /// accordion and survives normalization (single-child accordions are exempt from flattening),
    /// so `layout accordion` + `join-with right` crashed the WM on the next layout tick.
    func testFullLayoutPassOverContainerInsideAccordionDoesNotCrash() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            // A tiles container nested directly inside an accordion parent
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.rootTilingContainer.setLayout(.accordion)

        try await workspace.layoutWorkspace() // used to die() here

        XCTAssertEqual(workspace.rootTilingContainer.layout, .accordion)
        XCTAssertEqual(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(),
            [1, 2, 3],
            "all windows survive the layout pass",
        )
    }

    func testLayoutCommandAccordionRoundTrip() async throws {
        let workspace = Workspace.get(byName: name)
        var w1: Window!
        workspace.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        XCTAssertEqual(w1.focusWindow(), true)

        await parseCommand("layout accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace() // used to die here
        XCTAssertEqual(workspace.rootTilingContainer.layout, .accordion)

        await parseCommand("layout tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        XCTAssertEqual(workspace.rootTilingContainer.layout, .tiles)
    }
}
