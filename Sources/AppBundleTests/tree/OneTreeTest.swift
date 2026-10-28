@testable import AppBundle
import Common
import XCTest

/// Step 5: one tree. Snapshots are values taken on demand; nothing is cached beside the tree, and
/// applying a transformed snapshot keeps the containers it names.
@MainActor
final class OneTreeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCommitsKeepContainerIdentity() {
        let ws = focus.workspace
        let root = ws.rootTilingContainer
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)
        TestWindow.new(id: 4, parent: ws.floatingWindowsContainer)

        XCTAssertTrue(ws.commitTilingUnfloat(windowId: 4))

        XCTAssertTrue(ws.rootTilingContainer === root, "the root survives a structural commit")
        XCTAssertTrue(Window.get(byId: 2)?.parent === nested, "so do nested containers")
        XCTAssertEqual(Set(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)), [1, 2, 3, 4])
    }

    func testSnapshotsCarryIdsButCompareByStructure() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let snapshot = ws.currentTilingSpine()
        XCTAssertEqual(snapshot.containerId, ws.rootTilingContainer.nodeId)
        let sameShape = PersistentTilingNode.container(orientation: ws.rootTilingContainer.orientation, layout: .tiles, weight: 1, children: [.window(id: 1, weight: 1)])
        XCTAssertEqual(snapshot, sameShape)
    }

    func testTheSyncMachineryStaysGone() throws {
        let appBundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle")
        let gone = ["tilingStructureGeneration", "invalidateTilingStructureGeneration", "suppressTilingGenerationInvalidation",
                    "withSuppressedGenerationInvalidation", "SpineInvariant", "TreeHistory", "_tilingSpineByName"]
        for file in FileManager.default.enumerator(at: appBundle, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
            where file.pathExtension == "swift"
        {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
                .joined(separator: "\n")
            for name in gone where code.contains(name) {
                XCTFail("\(file.lastPathComponent) brings back `\(name)` — there is one tree; a second copy needs syncing")
            }
        }
    }
}
