@testable import AppBundle
import Common
import XCTest

/// Drives the REAL production pipeline — command parser → light session (focus sync, hygiene,
/// command body, layout, side UI, follow-up heavy) — against `TestWindow`s, headlessly.
///
/// Everything that would leave the process is refused by `Headless` (see `OutwardEffect`), and the
/// default WindowServer port is empty, so a test can run any command string exactly as a hotkey
/// would without touching the user's desktop or a running AeroSpace. Tree shape is asserted with
/// `i3Tree`, geometry with `TestWindow` rects written by layout.
@MainActor
enum HeadlessHarness {
    /// Runs `command` (full shell syntax, e.g. `"focus left && move right"`) as a hotkey binding
    /// would: one light session, then waits for any follow-up heavy to finish so assertions see the
    /// settled state.
    @discardableResult
    static func run(_ command: String, file: StaticString = #filePath, line: UInt = #line) async throws -> CmdResult {
        let parsed = parseCommand(command)
        let shell: Shell<any Command>
        switch parsed {
            case .cmd(let s): shell = s
            case .help: XCTFail("help isn't a command", file: file, line: line); return CmdResult(stdout: [], stderr: [], exitCode: .fail)
            case .failure(let e):
                XCTFail("Can't parse '\(command)': \(e.msg)", file: file, line: line)
                return CmdResult(stdout: [], stderr: [e.msg], exitCode: .fail)
        }
        let io = CmdIoImpl(stdin: .emptyStdin)
        let exitCode = try await runLightSession(.hotkeyBinding, .forceRun) { () throws in
            await shell.run(.defaultEnv, io)
        }
        await settle()
        return CmdResult(stdout: io.stdout, stderr: io.stderr, exitCode: exitCode)
    }

    /// Run `commands` in order, each its own session (like pressing hotkeys one after another).
    static func run(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        for c in commands { try await run(c, file: file, line: line) }
    }

    /// One heavy (discovery + native-state normalization + layout), as an AX notification would.
    static func heavy() async {
        await runHeavyCompleteRefreshSession(.ax("test"), assumeCancellable: false)
    }

    /// Wait until no scheduled heavy is in flight.
    static func settle() async {
        // A finishing heavy may schedule another (e.g. a light re-queued cancelled discovery)
        for _ in 0 ..< 100 {
            guard let task = activeRefreshTask else { return }
            _ = await task.result
            if activeRefreshTask == task { activeRefreshTask = nil }
        }
    }

    /// Asserts no outward effect other than `allowed` was even attempted. Refused attempts are
    /// harmless, but an effect nobody expected in a given scenario is usually a bug in its own right
    /// (e.g. a query command rebuilding on-screen UI).
    static func assertOnlyAttempted(_ allowed: Set<OutwardEffect>, file: StaticString = #filePath, line: UInt = #line) {
        let unexpected = Headless.blockedAttempts.filter { !allowed.contains($0.key) }
        XCTAssertTrue(unexpected.isEmpty, "unexpected outward effects attempted: \(unexpected)", file: file, line: line)
    }
}

extension TreeNode {
    /// Compact i3-style tree string: `h[1 v[2 3*]]`. Containers: `h`/`v` tiles, `ha`/`va` accordion,
    /// `hm`/`vm` master. `*` marks the focused window; `f(...)` the floating layer.
    @MainActor var i3Tree: String {
        switch nodeCases {
            case .window(let w): return "\(w.windowId)" + (focus.windowOrNil === w ? "*" : "")
            case .workspace(let ws):
                let floats = ws.floatingWindows
                let tiling = ws.rootTilingContainer.i3Tree
                return floats.isEmpty ? tiling : tiling + " f(" + floats.map(\.i3Tree).joined(separator: " ") + ")"
            case .tilingContainer(let c):
                let o = c.orientation == .h ? "h" : "v"
                let l = switch c.layout {
                    case .tiles: ""
                    case .accordion: "a"
                    case .master: "m"
                }
                return o + l + "[" + c.children.map(\.i3Tree).joined(separator: " ") + "]"
            case .floatingWindowsContainer(let c): return "f(" + c.children.map(\.i3Tree).joined(separator: " ") + ")"
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                return "<macos>"
        }
    }
}
