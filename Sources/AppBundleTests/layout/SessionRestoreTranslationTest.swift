@testable import AppBundle
import XCTest

final class SessionRestoreTranslationTest: XCTestCase {
    func testExactIdsNeedNoTranslation() {
        let map = sessionRestoreIdTranslation(
            savedIds: [1, 2],
            savedApps: [1: "a", 2: "b"],
            liveIds: [1, 2],
            liveApp: { $0 == 1 ? "a" : "b" },
        )
        XCTAssertTrue(map.isEmpty)
    }

    func testIdCollisionWithDifferentAppIsEvicted() {
        // Post-reboot: live id 1 numerically collides with a DEAD saved id of another app.
        // It must not be spliced into the saved layout as if it were the same window.
        let map = sessionRestoreIdTranslation(
            savedIds: [1],
            savedApps: [1: "terminal"],
            liveIds: [1],
            liveApp: { _ in "browser" }, // same id, different app
        )
        // No terminal window exists to re-pair with → evicted via the dead sentinel.
        XCTAssertEqual(map, [1: 0])
    }

    func testIdCollisionRepairsToSameAppWindow() {
        // Saved terminal id 1 collides with a live browser window 1; the real terminal
        // relaunched as id 50 — pairing must route 1 → 50, leaving live 1 alone.
        let map = sessionRestoreIdTranslation(
            savedIds: [1],
            savedApps: [1: "terminal"],
            savedWorkspaceById: [1: "2"],
            liveIds: [1, 50],
            liveApp: { $0 == 1 ? "browser" : "terminal" },
        )
        XCTAssertEqual(map, [1: 50])
    }

    func testRebootRemapsByAppInOrder() {
        // All ids changed (reboot). Two Safari windows + one Mail window relaunched with new ids.
        let savedApps: [UInt32: String] = [10: "safari", 11: "safari", 20: "mail"]
        let liveApp: (UInt32) -> String? = { id in
            switch id {
                case 100, 101: "safari"
                case 200: "mail"
                default: nil
            }
        }
        let map = sessionRestoreIdTranslation(
            savedIds: [10, 11, 20],
            savedApps: savedApps,
            savedWorkspaceById: [10: "1", 11: "1", 20: "2"],
            liveIds: [100, 101, 200],
            liveApp: liveApp,
        )
        // Ascending order pairing: 10→100, 11→101, 20→200
        XCTAssertEqual(map, [10: 100, 11: 101, 20: 200])
    }

    func testMultiWorkspaceAppIsNotTranslated() {
        // Terminal windows spread across ws2/ws3: order-pairing could shuffle them across
        // workspaces — refuse to translate rather than guess.
        let map = sessionRestoreIdTranslation(
            savedIds: [10, 11],
            savedApps: [10: "term", 11: "term"],
            savedWorkspaceById: [10: "2", 11: "3"],
            liveIds: [100, 101],
            liveApp: { _ in "term" },
        )
        XCTAssertTrue(map.isEmpty)
    }

    func testUnpairableIdsStayUnmapped() {
        // Saved app has no live windows; extra live app has no saved slot.
        let map = sessionRestoreIdTranslation(
            savedIds: [10],
            savedApps: [10: "gone-app"],
            liveIds: [100],
            liveApp: { _ in "new-app" },
        )
        XCTAssertTrue(map.isEmpty)
    }

    func testPartialRebootMixesExactAndRemapped() {
        // Window 1 survived (same id); Safari relaunched (10 → 100).
        let map = sessionRestoreIdTranslation(
            savedIds: [1, 10],
            savedApps: [1: "term", 10: "safari"],
            liveIds: [1, 100],
            liveApp: { $0 == 100 ? "safari" : "term" },
        )
        XCTAssertEqual(map, [10: 100])
    }

    func testSpineMappingRewritesIds() {
        let spine = PersistentTilingNode.container(
            orientation: .h, layout: .tiles, weight: 1,
            children: [.window(id: 10, weight: 1), .window(id: 20, weight: 2)],
        )
        let mapped = spine.mappingWindowIds([10: 100])
        XCTAssertEqual(
            mapped,
            .container(
                orientation: .h, layout: .tiles, weight: 1,
                children: [.window(id: 100, weight: 1), .window(id: 20, weight: 2)],
            ),
        )
    }
}
