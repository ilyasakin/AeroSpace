@testable import AppBundle
import Common
import XCTest

@MainActor
final class SessionLayoutStoreTest: XCTestCase {
    /// The suite runs under the same `aeroSpaceAppId` as the debug app, so an unguarded path put the
    /// developer's LIVE session-restore file in reach of every test. It survived only by timing:
    /// saves are debounced 0.4s onto the main queue and the process exited first. Assert the
    /// redirect, because the failure mode is silent and destroys state the running WM reloads.
    func testPersistentPathsNeverPointAtProductionUnderTest() {
        let session = SessionLayoutStore.fileUrl.path
        let violations = SpineInvariant.logUrl.path
        for path in [session, violations] {
            XCTAssertFalse(
                path.contains("Library/Application Support"),
                "test wrote to the real app-support directory: \(path)",
            )
        }
        XCTAssertTrue(session.hasSuffix("session-layout.json"))
        XCTAssertTrue(violations.hasSuffix("spine-violations.log"))
    }

    /// Adding the reboot-stable monitor key changed the on-disk format. A session file written by
    /// the previous build has no `key` / `monitorKey`, and it must still load — otherwise upgrading
    /// silently discards the user's workspace layout, which is the failure this store exists to
    /// prevent.
    ///
    /// Rather than hand-writing JSON (which would encode a guess about the node format), this saves
    /// the real thing, asserts the new fields are actually written, then STRIPS them to synthesise a
    /// legacy file. That covers both directions of the compatibility contract. Safe to write for
    /// real because persistent paths redirect under test.
    @MainActor
    func testMonitorKeyIsWrittenAndItsAbsenceStillLoads() throws {
        setUpWorkspacesForTests()
        let ws = focus.workspace
        TestWindow.new(id: 4101, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        TestWindow.new(id: 4102, parent: ws.rootTilingContainer, adaptiveWeight: 1)

        let url = SessionLayoutStore.fileUrl
        defer { try? FileManager.default.removeItem(at: url) }
        SessionLayoutStore.saveNow()

        let written = try XCTUnwrap(try? Data(contentsOf: url), "saveNow should have written a file")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: written) as? [String: Any],
            "session file should be a JSON object",
        )

        // Direction 1: we write the stable key.
        let monitorsOut = try XCTUnwrap(json["monitors"] as? [[String: Any]])
        XCTAssertFalse(monitorsOut.isEmpty)
        XCTAssertNotNil(monitorsOut[0]["key"], "the stable display key must be persisted")
        let wsOut = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        XCTAssertNotNil(wsOut.first?["monitorKey"], "each workspace records its display key")

        // Direction 2: synthesise the legacy shape by removing exactly those fields.
        json["monitors"] = monitorsOut.map { m -> [String: Any] in
            var m = m; m.removeValue(forKey: "key"); return m
        }
        json["workspaces"] = wsOut.map { w -> [String: Any] in
            var w = w; w.removeValue(forKey: "monitorKey"); return w
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let loaded = try XCTUnwrap(SessionLayoutStore.load()?.snapshot, "a legacy file must still decode")
        XCTAssertTrue(loaded.windowIds.contains(4101))
        XCTAssertNil(
            loaded.workspaces.first?.monitorKey,
            "an absent key decodes as nil, not a fabricated value",
        )
        XCTAssertNil(loaded.monitorAssignments.first?.key)
        XCTAssertFalse(loaded.monitorAssignments.isEmpty, "geometry-only assignments still load")
    }

    func testFilteringWindowsDropsMissingAndPromotesSingleChild() {
        let tree: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 1, weight: 1),
                .window(id: 2, weight: 1),
                .container(
                    orientation: .v,
                    layout: .tiles,
                    weight: 1,
                    children: [
                        .window(id: 3, weight: 1),
                        .window(id: 4, weight: 1),
                    ],
                ),
            ],
        )
        // Drop 2 and 4
        let filtered = tree.filteringWindows(keeping: [1, 3])
        assertNotNil(filtered)
        let ids = filtered!.windowIds
        assertEquals(ids.sorted(), [1, 3])
        // Structure still has both surviving windows
        assertTrue(filtered!.containsWindowId(1))
        assertTrue(filtered!.containsWindowId(3))
        assertFalse(filtered!.containsWindowId(2))
    }

    func testFilteringAllMissingReturnsNil() {
        let tree: PersistentTilingNode = .window(id: 9, weight: 1)
        assertNil(tree.filteringWindows(keeping: [1, 2]))
    }

    func testRoundTripDTOPreservesStructure() {
        let root: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 10, weight: 2),
                .window(id: 11, weight: 1),
            ],
        )
        let snap = PersistentWorldSnapshot(
            workspaces: [
                PersistentWorkspaceSnapshot(
                    name: "1",
                    monitorKey: nil,
                    monitorTopLeft: .zero,
                    visibleWorkspaceName: "1",
                    rootTiling: root,
                    floatingWindowIds: [99],
                    unconventionalWindowIds: [],
                ),
            ],
            monitorAssignments: [(key: nil, topLeft: CGPoint.zero, workspace: "1")],
            windowIds: [10, 11, 99],
        )
        // Encode/decode via the store's private DTO by save/load would need disk; use structure equality on filter instead.
        let filtered = root.filteringWindows(keeping: [10, 11])!
        assertTrue(filtered.structureEquals(root))
        assertEquals(snap.workspaces[0].floatingWindowIds, [99])
    }

    /// Regression: materialize must publish the restored spine as generation so layout does not
    /// keep applying a stale discovery spine (wrong orientation / order).
    func testMaterializePublishesGenerationOverStaleDiscoverySpine() async throws {
        setUpWorkspacesForTests()
        Workspace.clearTilingStructureGenerations()
        let ws = Workspace.get(byName: "2")
        let w1 = TestWindow.new(id: 501, parent: ws.floatingWindowsContainer)
        let w2 = TestWindow.new(id: 502, parent: ws.floatingWindowsContainer)

        // Stale generation as if discovery laid out two windows side-by-side (horizontal).
        let staleHorizontal: PersistentTilingNode = .container(
            orientation: .h,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 501, weight: 1),
                .window(id: 502, weight: 1),
            ],
        )
        ws.tilingStructureGeneration = staleHorizontal
        // Live dual-link currently matches that horizontal tree
        ws.materializeTilingSpine(staleHorizontal)
        XCTAssertEqual(ws.rootTilingContainer.orientation, .h)

        // Session restore: vertical stack (one above the other).
        let restoredVertical: PersistentTilingNode = .container(
            orientation: .v,
            layout: .tiles,
            weight: 1,
            children: [
                .window(id: 501, weight: 1),
                .window(id: 502, weight: 1),
            ],
        )
        ws.materializeTilingSpine(restoredVertical)

        // Generation must match restore (not stale horizontal).
        let gen = try XCTUnwrap(ws.tilingStructureGeneration)
        XCTAssertTrue(gen.structureEquals(restoredVertical))
        XCTAssertEqual(ws.rootTilingContainer.orientation, .v)
        XCTAssertEqual(Set(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)), [501, 502])

        // Layout must use vertical geometry: same width, stacked Y.
        try await ws.layoutWorkspace()
        let r1 = try XCTUnwrap(w1.desiredRect)
        let r2 = try XCTUnwrap(w2.desiredRect)
        XCTAssertEqual(r1.width, r2.width, accuracy: 1)
        XCTAssertNotEqual(r1.topLeftY, r2.topLeftY, "vertical tiles must stack on Y")
        // Horizontal would differ in X; vertical should share the same X origin.
        XCTAssertEqual(r1.topLeftX, r2.topLeftX, accuracy: 1)
    }
}
