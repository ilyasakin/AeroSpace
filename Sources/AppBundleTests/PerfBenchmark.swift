@testable import AppBundle
import Common
import XCTest

/// Microbenchmarks for the tree/refresh hot paths. Not a pass/fail test — it prints timings
/// so before/after deltas can be compared. Run with:
///   swift test --filter PerfBenchmark 2>&1 | grep BENCH
@MainActor
final class PerfBenchmark: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func buildTree(workspaces: Int, windowsPerWorkspace: Int) {
        var id: UInt32 = 1
        for w in 0 ..< workspaces {
            let ws = Workspace.get(byName: "bench-\(w)")
            var parent: TilingContainer = ws.rootTilingContainer
            for i in 0 ..< windowsPerWorkspace {
                TestWindow.new(id: id, parent: parent)
                id += 1
                // Every 3rd window, nest a container to give the tree real depth
                if i % 3 == 2 {
                    parent = TilingContainer.newVTiles(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                }
            }
        }
    }

    private func time(_ label: String, iterations: Int, _ body: () -> Void) {
        // warmup
        for _ in 0 ..< 3 { body() }
        let start = DispatchTime.now()
        for _ in 0 ..< iterations { body() }
        let nanos = unsafe DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let usPerIter = Double(nanos) / Double(iterations) / 1000
        print("BENCH \(label): \(String(format: "%.1f", usPerIter)) µs/iter")
    }

    func testTreeHotPaths() {
        buildTree(workspaces: 20, windowsPerWorkspace: 30)

        let wsList = Array(Workspace.allUnsorted) // isolate accessor cost from list construction
        let oneWs = wsList[0]

        time("Workspace.all (sorted)", iterations: 5000) {
            var n = 0
            for _ in Workspace.all { n += 1 }
            XCTAssertGreaterThan(n, 0)
        }

        time("Workspace.allUnsorted", iterations: 5000) {
            var n = 0
            for _ in Workspace.allUnsorted { n += 1 }
            XCTAssertGreaterThan(n, 0)
        }

        time("allLeafWindowsRecursive (all ws)", iterations: 2000) {
            var n = 0
            for ws in wsList { n += ws.allLeafWindowsRecursive.count }
            XCTAssertGreaterThan(n, 0)
        }

        time("rootTilingContainer accessor (1 ws)", iterations: 200_000) {
            _ = oneWs.rootTilingContainer
        }

        time("normalizeContainers (all ws)", iterations: 1000) {
            for ws in wsList { ws.normalizeContainers() }
        }

        // parentsWithSelf on a deep leaf
        let deepLeaf = Workspace.get(byName: "bench-10").allLeafWindowsRecursive.last!
        time("parentsWithSelf (deep leaf)", iterations: 50000) {
            _ = deepLeaf.parentsWithSelf.count
        }

        // nodeCases / getChildParentRelation cast-chain cost (via getWeight)
        let tiledWindow = Workspace.get(byName: "bench-5").rootTilingContainer.allLeafWindowsRecursive.first!
        time("getChildParentRelation (getWeight)", iterations: 500_000) {
            _ = tiledWindow.getWeight(.h)
        }
        time("nodeCases", iterations: 500_000) {
            _ = tiledWindow.nodeCases
        }
    }
}
