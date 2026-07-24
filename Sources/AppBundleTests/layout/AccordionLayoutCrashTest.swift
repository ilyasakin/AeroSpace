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
        // Mutate live layout the way LayoutCommand does — must also invalidate the generation
        workspace.rootTilingContainer.setLayout(.accordion)
        XCTAssertNil(workspace.tilingStructureGeneration, "setLayout must invalidate the published spine")

        // The crash fired on the next layout tick — run a real layout pass
        try await workspace.layoutWorkspace()

        // Still alive, and the published generation reflects the accordion
        guard case .container(_, let layout, _, _)? = workspace.tilingStructureGeneration else {
            XCTFail("layout must publish a generation")
            return
        }
        XCTAssertEqual(layout, .accordion)
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
