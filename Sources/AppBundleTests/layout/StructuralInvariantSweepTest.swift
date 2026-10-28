@testable import AppBundle
import Common
import XCTest

/// Every structure-touching command, across representative tree shapes: afterwards the tree must be
/// well-formed — each window in it exactly once — and the render must place exactly the tiled
/// windows. (This swept for a cached tiling spine drifting from the live tree until step 5 of the
/// re-architecture removed the cache; the sweep itself stays useful.)
@MainActor
final class StructuralInvariantSweepTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    /// What is wrong with `workspace`'s tree, if anything
    private func structuralProblems(_ workspace: Workspace) -> [String] {
        var problems: [String] = []
        let all = Workspace.all.flatMap(\.allLeafWindowsRecursive).map(\.windowId)
        if Set(all).count != all.count { problems.append("a window appears twice: \(all)") }
        let tiled = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        let rendered = render(workspace, spine: workspace.currentTilingSpine()).tiles.map(\.windowId)
        if rendered != tiled { problems.append("render placed \(rendered), tree tiles \(tiled)") }
        return problems
    }

    // MARK: - Tree shapes

    /// Each shape is built fresh per command so one command's damage can't be blamed on the next.
    private struct Shape {
        let name: String
        let build: @MainActor (Workspace) -> Void
    }

    private var shapes: [Shape] {
        [
            Shape(name: "single-window") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
            },
            Shape(name: "two-flat") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
            },
            Shape(name: "three-flat") { ws in
                for id in UInt32(1) ... 3 {
                    TestWindow.new(id: id, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                }
            },
            Shape(name: "nested-vsplit") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                }
            },
            Shape(name: "deep-nest") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply { v in
                    TestWindow.new(id: 2, parent: v, adaptiveWeight: 1)
                    TilingContainer.newHTiles(parent: v, adaptiveWeight: 1).apply { h in
                        TestWindow.new(id: 3, parent: h, adaptiveWeight: 1)
                        TestWindow.new(id: 4, parent: h, adaptiveWeight: 1)
                    }
                }
            },
            Shape(name: "accordion-root") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                ws.rootTilingContainer.setLayout(.accordion)
            },
            Shape(name: "accordion-with-container") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                }
                ws.rootTilingContainer.setLayout(.accordion)
            },
            Shape(name: "tiles-plus-floating") { ws in
                TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
                TestWindow.new(id: 3, parent: ws.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
            },
            Shape(name: "only-floating") { ws in
                TestWindow.new(id: 1, parent: ws.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
            },
        ]
    }

    /// Commands that can touch tiling structure, focus, or layout. Query-only commands (list-*, echo,
    /// true/false) are excluded — they cannot mutate, so they cannot break the contract, and running
    /// them would only pad the matrix. `exec-and-forget`, `enable`, config and callback commands are
    /// excluded because they reach outside the model.
    private var commands: [String] {
        [
            // layout
            "layout tiles", "layout accordion", "layout horizontal", "layout vertical",
            "layout tiling", "layout floating",
            "layout tiles horizontal", "layout tiles vertical", "layout accordion horizontal",
            // structure
            "split horizontal", "split vertical", "split opposite",
            "join-with right", "join-with left", "join-with up", "join-with down",
            "toggle-group", "flatten-workspace-tree", "balance-sizes",
            // movement
            "move right", "move left", "move up", "move down",
            "move-node-to-workspace B", "move-node-to-workspace next",
            "swap right", "swap left", "swap dfs-next", "swap dfs-prev",
            // focus
            "focus right", "focus left", "focus up", "focus down",
            "focus dfs-next", "focus dfs-prev", "focus-back-and-forth",
            // sizing
            "resize width +100", "resize height -50", "resize smart +80",
            "resize-to 400 300", "center-window",
            // window state
            "fullscreen", "fullscreen on", "fullscreen off",
            // NOTE: macos-native-minimize and macos-native-fullscreen are deliberately absent.
            // Both call `window.asMacWindow()`, which is `self as! MacWindow`, so they trap on a
            // TestWindow. That is a harness limitation, not a product bug — in production every
            // window really is a MacWindow. (The force cast is still a latent fragility: it is the
            // only thing standing between a future non-MacWindow subclass and a crash.)
            "always-on-top on", "always-on-top off", "sticky on", "sticky off",
            // workspace
            "workspace B", "workspace next", "workspace prev", "workspace-back-and-forth",
            "summon-workspace B", "toggle-special-workspace S",
            // policy / misc structural
            "tiling-policy dwindle", "tiling-policy manual",
            "close", "close-all-windows-but-current",
            "mode main",
            // i3 parity
            "focus parent", "focus child", "focus next", "focus prev", "focus next-sibling",
            "focus prev-sibling", "focus floating", "focus tiling", "focus mode-toggle",
            "focus parent && move right", "focus parent && move up", "focus parent && close",
            "focus parent && move-node-to-workspace B", "focus parent && layout h_accordion",
            "mark m && move-node-to-mark m", "mark m && swap --with-mark m",
            "scratchpad move", "scratchpad move && scratchpad show",
            "layout h_tiles v_tiles h_accordion", "resize right +50", "resize up -20",
            "move-node-to-workspace back-and-forth", "gaps inner current plus 5",
            "rename-workspace renamed", "[all] focus", "criteria tiling -- move left",
        ]
    }

    // MARK: - The sweep

    /// A `die()` inside a command takes the whole process down, so nothing buffered survives to say
    /// which pair did it. Run with `SWEEP_TRACE=1` to get an unbuffered line per pair; the last line
    /// written names the culprit. Off by default — 540 lines of trace per run is noise.
    private static let traceEnabled = ProcessInfo.processInfo.environment["SWEEP_TRACE"] == "1"
    private func trace(_ s: String) {
        guard Self.traceEnabled else { return }
        FileHandle.standardError.write(Data(("TRACE " + s + "\n").utf8))
    }

    func testEveryCommandPreservesTheStructuralInvariant() async throws {
        var violations: [String] = []
        var ran = 0
        var unparseable: [String] = []
        var threw: [String] = []

        for shape in shapes {
            for command in commands {
                trace("\(shape.name) / \(command)")
                setUpWorkspacesForTests()

                let workspace = focus.workspace
                shape.build(workspace)
                // Focus a leaf so direction-relative commands have a subject.
                workspace.rootTilingContainer.allLeafWindowsRecursive.first?.focusWindow()

                try? await workspace.layoutWorkspace()

                let parsed = parseCommand(command)
                guard let cmd = parsed.cmdOrNil else {
                    unparseable.append(command)
                    continue
                }

                _ = await cmd.run(.defaultEnv, .emptyStdin)

                do {
                    try await focus.workspace.layoutWorkspace()
                    if focus.workspace !== workspace, !workspace.isEffectivelyEmpty {
                        try await workspace.layoutWorkspace()
                    }
                } catch {
                    threw.append("\(shape.name) / \(command): \(error)")
                }

                ran += 1
                let reported = structuralProblems(workspace)
                if !reported.isEmpty {
                    let first = reported[0]
                        .split(separator: "\n")
                        .prefix(3)
                        .joined(separator: " | ")
                    violations.append("\(shape.name) / \(command)  ->  \(first)")
                }
            }
        }

        XCTAssertGreaterThan(ran, 400, "sanity: the matrix should actually be large")

        if !unparseable.isEmpty {
            // Not a failure — it means this test's command list drifted from the real CLI surface,
            // which is worth knowing but is not a product bug.
            print("SWEEP: \(unparseable.count) command strings did not parse: \(Set(unparseable).sorted())")
        }
        if !threw.isEmpty {
            print("SWEEP: \(threw.count) layout passes threw:\n  " + threw.prefix(10).joined(separator: "\n  "))
        }

        print("SWEEP: ran \(ran) (shape, command) pairs; \(violations.count) structural violations")
        if !violations.isEmpty {
            print("SWEEP VIOLATIONS:\n  " + violations.joined(separator: "\n  "))
        }

        XCTAssertEqual(
            violations.count, 0,
            """
            The tree was left malformed after these commands:
            \(violations.joined(separator: "\n"))
            """,
        )
    }

    /// Command PAIRS: some damage only shows once a second operation builds on the first.
    func testCommandPairsPreserveTheStructuralInvariant() async throws {
        let interesting = [
            "layout accordion", "layout tiles", "join-with right", "split vertical",
            "toggle-group", "move right", "swap right", "flatten-workspace-tree",
            "layout floating", "layout tiling", "fullscreen", "balance-sizes",
        ]
        var violations: [String] = []
        var ran = 0

        for first in interesting {
            for second in interesting {
                setUpWorkspacesForTests()

                let workspace = focus.workspace
                TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 1)
                TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                }
                workspace.rootTilingContainer.allLeafWindowsRecursive.first?.focusWindow()
                try? await workspace.layoutWorkspace()

                for command in [first, second] {
                    guard let cmd = parseCommand(command).cmdOrNil else { continue }
                    _ = await cmd.run(.defaultEnv, .emptyStdin)
                    try? await focus.workspace.layoutWorkspace()
                }

                ran += 1
                let reported = structuralProblems(workspace)
                if !reported.isEmpty {
                    violations.append("\(first) THEN \(second)  ->  \(reported[0].split(separator: "\n").prefix(3).joined(separator: " | "))")
                }
            }
        }

        print("SWEEP PAIRS: ran \(ran) pairs; \(violations.count) violations")
        if !violations.isEmpty {
            print("SWEEP PAIR VIOLATIONS:\n  " + violations.joined(separator: "\n  "))
        }
        XCTAssertEqual(violations.count, 0, violations.joined(separator: "\n"))
    }
}
