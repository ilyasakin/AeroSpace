@testable import AppBundle
import Common
import XCTest

/// Weight SCALE compatibility across container boundaries.
///
/// Tiles containers have their child weights renormalized to spans by layout (~hundreds of px).
/// Accordion containers never normalize theirs, so accordion children keep their authored ratio
/// scale (~1). Moving a child from an accordion into a tiles container while carrying its weight
/// therefore mixes scales — and since normalization is proportional, a weight-1 child beside
/// weight-800 siblings renders as an invisible sliver. (Additive normalization used to mask this by
/// equalizing everything, so this only became observable with proportional normalization.)
@MainActor
final class ToggleGroupWeightScaleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func widths(_ workspace: Workspace) -> [CGFloat] {
        workspace.rootTilingContainer.allLeafWindowsRecursive
            .compactMap { $0.lastAppliedLayoutVirtualRect?.width }
    }

    /// Unwrapping a group must subdivide the slot the GROUP occupied — every window stays visible.
    func testUnwrapGroupKeepsWindowsVisible() async throws {
        let workspace = Workspace.get(byName: name)
        var grouped: Window!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                grouped = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        // One layout puts the ROOT's children on span scale (~px) while the accordion's children
        // keep ratio scale — exactly the mismatch that unwrapping used to carry across.
        try await workspace.layoutWorkspace()
        XCTAssertEqual(grouped.focusWindow(), true)

        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        let w = widths(workspace)
        try XCTSkipIf(w.count != 3, "expected 3 tiled windows, got \(w.count)")
        let total = w.reduce(0, +)
        for (i, width) in w.enumerated() {
            XCTAssertGreaterThan(
                width / total, 0.05,
                "window \(i) collapsed to \(width)px of \(total) — weight scale was not converted",
            )
        }
    }

    /// The group's slot is preserved: two unwrapped equal children together occupy what the group
    /// had, so the untouched sibling keeps its own share.
    func testUnwrapPreservesTheGroupsShare() async throws {
        let workspace = Workspace.get(byName: name)
        var grouped: Window!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                grouped = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        try await workspace.layoutWorkspace()
        let before = widths(workspace)
        try XCTSkipIf(before.isEmpty, "no laid-out windows")
        let loneBefore = before[0]

        XCTAssertEqual(grouped.focusWindow(), true)
        await parseCommand("toggle-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        let after = widths(workspace)
        try XCTSkipIf(after.count != 3, "expected 3 tiled windows, got \(after.count)")
        XCTAssertEqual(after[0], loneBefore, accuracy: 2, "the untouched sibling keeps its share")
        XCTAssertEqual(
            after[1] + after[2], loneBefore, accuracy: 4,
            "the two unwrapped windows together occupy the slot the group had",
        )
    }
}
