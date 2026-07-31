@testable import AppBundle
import Common
import XCTest

/// Regression: a workspace's layout intermittently flipped from side-by-side to stacked when
/// switching workspaces.
///
/// Two behaviours combined:
///
/// 1. Dwindle chooses a split by TILE ASPECT — that is the policy, and `normalizeContainers`
///    deliberately skips opposite-orientation alternation for it. But when the target window had no
///    laid-out rect yet, `placeNewWindow` fell back to *perpendicular to the parent*, which is
///    alternation. For the first split inside a horizontal root that yields a VERTICAL wrapper.
/// 2. Dwindle force-flattens single-child containers regardless of
///    `enable-normalization-flatten-containers`, because closing one half of a binary split leaves a
///    wrapper behind. So a root whose only child is a container has that child promoted TO root —
///    carrying its orientation with it.
///
/// Together: place a window before layout has run for it (discovery, a workspace switch) and the
/// root flips h -> v, turning `A | B` into `A` above `B`. Intermittent, because it depended purely
/// on whether the target happened to have been laid out yet.
@MainActor
final class DwindleRootOrientationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.tilingPolicy = .dwindle
        config.defaultRootContainerOrientation = .horizontal
        config.enableNormalizationFlattenContainers = false
    }

    /// The exact reported shape: one window with NO laid-out rect, then a second arrives.
    /// On a landscape monitor the pair must end up side by side.
    func testSplitWithNoLaidOutRectStaysHorizontalOnALandscapeMonitor() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        first.desiredRect = nil // not laid out yet — the workspace-switch case
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .h, "precondition: horizontal root")

        XCTAssertEqual(first.focusWindow(), true) // dwindle targets the focused tile
        let second = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        _ = workspace.commitTilingPlaceNewWindow(id: second.windowId)
        workspace.normalizeContainers()

        XCTAssertEqual(
            workspace.rootTilingContainer.orientation, .h,
            "a landscape workspace must split side-by-side, not stacked",
        )
        XCTAssertEqual(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(), [1, 2],
        )
    }

    /// With a real rect the aspect decides, as dwindle intends: a tall tile splits horizontally
    /// (stacked), a wide tile splits vertically (side by side).
    func testAspectStillDecidesWhenTheRectIsKnown() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 10, parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        // Tall tile → dwindle stacks.
        first.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 1200)

        XCTAssertEqual(first.focusWindow(), true)
        let second = TestWindow.new(id: 11, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        _ = workspace.commitTilingPlaceNewWindow(id: second.windowId)
        workspace.normalizeContainers()

        XCTAssertEqual(
            workspace.rootTilingContainer.orientation, .v,
            "a tall tile splits into a stacked pair — aspect, not alternation",
        )
    }
}
