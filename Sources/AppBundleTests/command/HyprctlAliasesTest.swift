@testable import AppBundle
import Common
import XCTest

@MainActor
final class HyprctlAliasesTest: XCTestCase {
    func testClientsAliasDefaultsToAllMonitors() {
        switch parseCmdArgs(["clients"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertEquals(args.filteringOptions.monitors, [.all])
            case .cmd:
                failExpectedActual("ListWindowsCmdArgs", "other")
            case .failure(let e):
                failExpectedActual("success", e.msg)
            case .help:
                failExpectedActual("cmd", "help")
        }
    }

    func testClientsWithAppBundleIdDoesNotPrependConflictingAll() {
        // Must not inject bare --all (conflicts with filtering); --monitor all is fine
        switch parseCmdArgs(["clients", "--app-bundle-id", "com.apple.finder"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertEquals(args.filteringOptions.monitors, [.all])
                assertEquals(args.filteringOptions.appIdFilter, "com.apple.finder")
            case .cmd:
                failExpectedActual("ListWindowsCmdArgs", "other")
            case .failure(let e):
                failExpectedActual("success", e.msg)
            case .help:
                failExpectedActual("cmd", "help")
        }
    }

    func testClientsWithPid() {
        switch parseCmdArgs(["clients", "--pid", "1234"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertEquals(args.filteringOptions.monitors, [.all])
                assertEquals(args.filteringOptions.pidFilter, 1234)
            case .failure(let e):
                failExpectedActual("success", e.msg)
            default:
                failExpectedActual("ListWindowsCmdArgs", "other")
        }
    }

    func testClientsAlreadyScopedDoesNotDoubleScope() {
        switch parseCmdArgs(["clients", "--focused"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertTrue(args.filteringOptions.focused)
            case .failure(let e):
                failExpectedActual("success", e.msg)
            default:
                failExpectedActual("ListWindowsCmdArgs", "other")
        }
    }

    func testActiveWindowAlias() {
        switch parseCmdArgs(["activewindow"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertTrue(args.filteringOptions.focused)
            case .cmd:
                failExpectedActual("ListWindowsCmdArgs", "other")
            case .failure(let e):
                failExpectedActual("success", e.msg)
            case .help:
                failExpectedActual("cmd", "help")
        }
    }

    func testWorkspacesAliasWithVisibleFilter() {
        // boolFlag: bare --visible → true; does not consume a following token
        switch parseCmdArgs(["workspaces", "--visible"].slice) {
            case .cmd(let args as ListWorkspacesCmdArgs):
                assertEquals(args.filteringOptions.onMonitors, [.all])
                assertEquals(args.filteringOptions.visible, true)
            case .failure(let e):
                failExpectedActual("success", e.msg)
            default:
                failExpectedActual("ListWorkspacesCmdArgs", "other")
        }
    }

    func testWorkspacesAliasWithEmptyFilter() {
        // boolFlag: `--empty no` → false
        switch parseCmdArgs(["workspaces", "--empty", "no"].slice) {
            case .cmd(let args as ListWorkspacesCmdArgs):
                assertEquals(args.filteringOptions.onMonitors, [.all])
                assertEquals(args.filteringOptions.empty, false)
            case .failure(let e):
                failExpectedActual("success", e.msg)
            default:
                failExpectedActual("ListWorkspacesCmdArgs", "other")
        }
    }

    func testWorkspacesAndMonitorsAliases() {
        assertNotNil(parseCmdArgs(["workspaces"].slice).cmdOrNil)
        assertNotNil(parseCmdArgs(["monitors"].slice).cmdOrNil)
        assertNotNil(parseCmdArgs(["binds"].slice).cmdOrNil)
    }

    func testJsonFlagOnAlias() {
        switch parseCmdArgs(["clients", "--json"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertTrue(args.json)
            default:
                failExpectedActual("json clients", "fail")
        }
        switch parseCmdArgs(["list-windows", "--all", "--json"].slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertTrue(args.json)
            default:
                failExpectedActual("list-windows --json", "fail")
        }
    }

    func testGlobalJsonInjectionForListCommands() {
        let processed = preprocessAerospaceCliArgs(["-j", "list-windows", "--all"])
        assertEquals(processed, ["list-windows", "--json", "--all"])
        switch parseCmdArgs(processed.slice) {
            case .cmd(let args as ListWindowsCmdArgs):
                assertTrue(args.json)
            default:
                failExpectedActual("injected --json", "fail")
        }

        let clients = preprocessAerospaceCliArgs(["clients", "-j"])
        assertEquals(clients, ["clients", "--json"])
    }

    func testGlobalJsonOnNonListIsNoOp() {
        // Must not inject --json into focus (unknown flag)
        let processed = preprocessAerospaceCliArgs(["-j", "focus", "left"])
        assertEquals(processed, ["focus", "left"])
        switch parseCmdArgs(processed.slice) {
            case .cmd(let args as FocusCmdArgs):
                assertEquals(args.cardinalOrDfsDirection, .direction(.left))
            case .failure(let e):
                failExpectedActual("focus left parses", e.msg)
            default:
                failExpectedActual("FocusCmdArgs", "other")
        }
    }

    func testShortJNotRewrittenAsFlagValue() {
        // --format takes a value; a literal -j value must not become --json
        let processed = rewriteShortJsonFlagInFlagPositions(["list-windows", "--all", "--format", "-j"])
        assertEquals(processed, ["list-windows", "--all", "--format", "-j"])
    }
}
