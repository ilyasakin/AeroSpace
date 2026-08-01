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

    /// Aspect still decides — but the aspect is PROJECTED from the model, not read from whatever
    /// rect a window happens to be carrying. Three windows in a horizontal root on a 1920x1080 test
    /// monitor give each tile ~640x1080, which is tall, so the next split stacks.
    func testProjectedAspectDecidesTheSplit() async throws {
        let workspace = focus.workspace
        var third: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 10, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 11, parent: $0, adaptiveWeight: 1)
            third = TestWindow.new(id: 12, parent: $0, adaptiveWeight: 1)
        }
        // A projected tile is now taller than it is wide, whatever any stale rect might say.
        let size = try XCTUnwrap(workspace.projectedTileSize(of: third))
        XCTAssertLessThan(size.width, size.height, "precondition: the projected tile is tall")
        third.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 9999, height: 1) // deliberately wrong

        XCTAssertEqual(third.focusWindow(), true)
        let fourth = TestWindow.new(id: 13, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        _ = workspace.commitTilingPlaceNewWindow(id: fourth.windowId)

        let parent = try XCTUnwrap(Window.get(byId: 13)?.parent as? TilingContainer)
        XCTAssertEqual(parent.orientation, .v, "a tall projected tile splits stacked")
        XCTAssertEqual(
            workspace.rootTilingContainer.orientation, .h,
            "and the root is untouched — the stale rect had no say",
        )
    }

    /// The projection is model-only: it must not consult layout output at all.
    func testProjectionIgnoresLayoutOutputEntirely() async throws {
        let workspace = focus.workspace
        var only: TestWindow!
        workspace.rootTilingContainer.apply {
            only = TestWindow.new(id: 20, parent: $0, adaptiveWeight: 1)
        }
        let withoutRect = try XCTUnwrap(workspace.projectedTileSize(of: only))
        only.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 9999)
        let withRect = try XCTUnwrap(workspace.projectedTileSize(of: only))
        XCTAssertEqual(withoutRect.width, withRect.width, accuracy: 0.001)
        XCTAssertEqual(withoutRect.height, withRect.height, accuracy: 0.001)
    }
}
