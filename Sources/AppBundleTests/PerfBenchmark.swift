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

    /// Microbenchmarks for the window-border dirty/occlusion hot path.
    /// Models a busy desktop: 20 bordered tiles + 80 non-bordered on-screen windows, and the
    /// three common WS-event shapes (unrelated move, bordered drag, occluder slide).
    /// Acceptance intent: each path stays well under 100 µs/iter on modest hardware so a 120 Hz
    /// drag burst cannot eat the main thread.
    func testWindowBordersHotPaths() {
        let borderCount = 20
        let stackExtra = 80
        let width = 4

        // Grid of bordered windows (visible tiles)
        var borderRegions: [(id: UInt32, region: Rect)] = []
        borderRegions.reserveCapacity(borderCount)
        var stack: [(id: UInt32, rect: Rect)] = []
        stack.reserveCapacity(borderCount + stackExtra)
        var managedIds = Set<UInt32>()
        for i in 0 ..< borderCount {
            let id = UInt32(i)
            let rect = Rect(topLeftX: CGFloat(i % 5) * 400, topLeftY: CGFloat(i / 5) * 300,
                            width: 380, height: 280)
            borderRegions.append((id, WindowBordersMath.region(rect: rect, width: width)))
            stack.append((id, rect))
            managedIds.insert(id)
        }
        // Non-managed on-screen windows (menus, other apps, etc.)
        for i in 0 ..< stackExtra {
            let id = UInt32(1000 + i)
            stack.append((id, Rect(topLeftX: CGFloat(i) * 20, topLeftY: 900, width: 15, height: 15)))
        }
        var stackIndex: [UInt32: Int] = [:]
        for (i, item) in stack.enumerated() { stackIndex[item.id] = i }

        let farOld = Rect(topLeftX: 5000, topLeftY: 5000, width: 50, height: 50)
        let farNew = Rect(topLeftX: 5050, topLeftY: 5050, width: 50, height: 50)
        let dragId: UInt32 = 3
        let dragOld = stack[Int(dragId)].rect
        let dragNew = Rect(topLeftX: dragOld.topLeftX + 12, topLeftY: dragOld.topLeftY + 8,
                           width: dragOld.width, height: dragOld.height)

        time("borders.overlapsAny (miss, 20 borders)", iterations: 200_000) {
            _ = WindowBordersMath.overlapsAnyBorder(regions: borderRegions, rect: farNew)
        }

        time("borders.affectedIds (unrelated miss)", iterations: 100_000) {
            _ = WindowBordersMath.affectedBorderIds(
                mover: 9999,
                moverIsBordered: false,
                borderRegions: borderRegions,
                oldRect: farOld,
                newRect: farNew,
            )
        }

        time("borders.affectedIds (bordered drag)", iterations: 100_000) {
            _ = WindowBordersMath.affectedBorderIds(
                mover: dragId,
                moverIsBordered: true,
                borderRegions: borderRegions,
                oldRect: dragOld,
                newRect: dragNew,
            )
        }

        // Full occlusion pass for every bordered window (worst-case full redraw math)
        time("borders.occluders (all 20, stack=100)", iterations: 20_000) {
            var n = 0
            for i in 0 ..< borderCount {
                let id = UInt32(i)
                let occ = WindowBordersMath.occluders(
                    id: id,
                    region: borderRegions[i].region,
                    isActive: id == 0,
                    activeId: 0,
                    activeRect: stack[0].rect,
                    stack: stack,
                    stackIndex: stackIndex[id],
                    managedIds: managedIds,
                )
                n += occ.count
            }
            XCTAssertGreaterThanOrEqual(n, 0)
        }

        // Incremental: only dirty set from a drag (typical live path after coalesce)
        time("borders.occluders (dirty≈3 after drag)", iterations: 100_000) {
            let dirty = WindowBordersMath.affectedBorderIds(
                mover: dragId,
                moverIsBordered: true,
                borderRegions: borderRegions,
                oldRect: dragOld,
                newRect: dragNew,
            )
            var n = 0
            for id in dirty {
                let idx = Int(id)
                let occ = WindowBordersMath.occluders(
                    id: id,
                    region: borderRegions[idx].region,
                    isActive: id == 0,
                    activeId: 0,
                    activeRect: stack[0].rect,
                    stack: stack,
                    stackIndex: stackIndex[id],
                    managedIds: managedIds,
                )
                n += occ.count
            }
            XCTAssertGreaterThanOrEqual(n, 0)
        }
    }
}
