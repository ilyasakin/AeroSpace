@testable import AppBundle
import Common
import XCTest

/// `Window.get(byId:)` must have REGISTRY semantics in tests, matching production's
/// `MacWindow.allWindowsMap`: a window is resolvable by id regardless of where — or whether — it is
/// bound in the tree.
///
/// Tests used to resolve by walking workspace trees, so an unbound window was invisible. That
/// forced `materializeTilingSpine` to park every leaf into the floating container under
/// `isUnitTest` before restoring (otherwise it could not resolve the ids it had just unbound), so
/// every materialize test exercised a different code path — and different MRU/generation side
/// effects — than production. These tests lock the semantics that let that hack be deleted.
@MainActor
final class WindowLookupTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWindowIsResolvableWhileBound() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply { TestWindow.new(id: 1, parent: $0) }
        XCTAssertEqual(Window.get(byId: 1)?.windowId, 1)
    }

    /// The property the park hack existed to work around.
    func testWindowStaysResolvableWhileUnbound() {
        let workspace = Workspace.get(byName: name)
        var w1: Window!
        workspace.rootTilingContainer.apply { w1 = TestWindow.new(id: 1, parent: $0) }
        w1.unbindFromParent()
        XCTAssertNil(w1.parent, "precondition: detached from the tree")
        XCTAssertEqual(
            Window.get(byId: 1)?.windowId, 1,
            "an unbound window must still resolve by id — materialize unbinds before it restores",
        )
    }

    /// Closing models production's garbageCollect: leaves the tree AND the registry.
    func testClosedWindowIsNotResolvable() {
        let workspace = Workspace.get(byName: name)
        var w1: TestWindow!
        workspace.rootTilingContainer.apply { w1 = TestWindow.new(id: 1, parent: $0) }
        w1.closeAxWindow()
        XCTAssertNil(Window.get(byId: 1), "a closed window must not resolve")
    }

    /// Materialize unbinds the old root and rebinds by id. With registry lookup this needs no
    /// parking, so the test path is the production path.
    func testMaterializeRebindsWithoutParking() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let spine = workspace.currentTilingSpine()
        workspace.materializeTilingSpine(spine)

        let ids = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        XCTAssertEqual(ids.sorted(), [1, 2], "both windows rebound into the tiling tree")
        XCTAssertTrue(
            workspace.floatingWindows.isEmpty,
            "no leftover parked floats — the isUnitTest park hack is gone",
        )
    }
}
