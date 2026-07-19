@testable import AppBundle
import Common
import XCTest

/// Microbenchmarks for the tree/refresh hot paths. Not a pass/fail test — it prints timings
/// so before/after deltas can be compared. Opt-in (it churns a 600-window tree and prints), so
/// it doesn't run in normal test runs. Enable with:
///   PERF_BENCH=1 swift test --filter PerfBenchmark 2>&1 | grep BENCH
@MainActor
final class PerfBenchmark: XCTestCase {
    private var benchEnabled: Bool { ProcessInfo.processInfo.environment["PERF_BENCH"] == "1" }

    override func setUp() async throws {
        try XCTSkipUnless(benchEnabled, "Set PERF_BENCH=1 to run the perf benchmark")
        setUpWorkspacesForTests()
    }

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
        let nsPerIter = Double(nanos) / Double(iterations)
        let usPerIter = nsPerIter / 1000
        print("BENCH \(label): \(String(format: "%.0f", nsPerIter)) ns/iter (\(String(format: "%.2f", usPerIter)) µs)")
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

    /// Microbenchmarks for the window-border dirty/occlusion hot path.
    /// Models a busy desktop: 20 bordered tiles + 80 non-bordered on-screen windows, and the
    /// three common WS-event shapes (unrelated move, bordered drag, occluder slide).
    ///
    /// Live path uses zero-heap APIs (`appendAffectedBorderIds` / `collectOccluders` into warm
    /// buffers). Target: **nanoseconds** per event for pure math (not µs from Set/Array alloc).
    func testWindowBordersHotPaths() {
        let borderCount = 20
        let width = 4

        // Grid of bordered windows (visible tiles)
        var borderRegions: [(id: UInt32, region: Rect)] = []
        borderRegions.reserveCapacity(borderCount)
        for i in 0 ..< borderCount {
            let id = UInt32(i)
            let rect = Rect(topLeftX: CGFloat(i % 5) * 400, topLeftY: CGFloat(i / 5) * 300,
                            width: 380, height: 280)
            borderRegions.append((id, WindowBordersMath.region(rect: rect, width: width)))
        }

        let farOld = Rect(topLeftX: 5000, topLeftY: 5000, width: 50, height: 50)
        let farNew = Rect(topLeftX: 5050, topLeftY: 5050, width: 50, height: 50)
        let dragId: UInt32 = 3
        let dragOld = borderRegions[Int(dragId)].region
        let dragNew = Rect(topLeftX: dragOld.topLeftX + 12, topLeftY: dragOld.topLeftY + 8,
                           width: dragOld.width, height: dragOld.height)

        // Warm reusable buffers (mirrors WindowBordersManager dirty tracking)
        var dirtyScratch = ContiguousArray<UInt32>()
        dirtyScratch.reserveCapacity(16)

        time("borders.overlapsAny (miss, 20 borders)", iterations: 1_000_000) {
            _ = WindowBordersMath.overlapsAnyBorder(regions: borderRegions, rect: farNew)
        }

        // Zero-heap live path (what handleWindowMoved uses after warm-up)
        time("borders.appendAffected (unrelated miss, zero-heap)", iterations: 1_000_000) {
            dirtyScratch.removeAll(keepingCapacity: true)
            WindowBordersMath.appendAffectedBorderIds(
                mover: 9999,
                moverIsBordered: false,
                borderRegions: borderRegions,
                oldRect: farOld,
                newRect: farNew,
                into: &dirtyScratch,
            )
        }

        time("borders.appendAffected (bordered drag, zero-heap)", iterations: 1_000_000) {
            dirtyScratch.removeAll(keepingCapacity: true)
            WindowBordersMath.appendAffectedBorderIds(
                mover: dragId,
                moverIsBordered: true,
                borderRegions: borderRegions,
                oldRect: dragOld,
                newRect: dragNew,
                into: &dirtyScratch,
            )
        }

    }
}
