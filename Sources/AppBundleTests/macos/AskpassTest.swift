@testable import AppBundle
import Common
import XCTest

@MainActor
final class AskpassTest: XCTestCase {
    private let me: uid_t = 501
    /// sudo (setuid root, real uid = the user) started by zsh started by claude; the client is sudo's child
    private func table(sudoPath: String = "/usr/bin/sudo", sudoRealUid: uid_t = 501, clientUid: uid_t = 501) -> [pid_t: AskpassProcess] {
        [
            100: AskpassProcess(pid: 100, parentPid: 90, realUid: clientUid, executablePath: "/x/aerospace", arguments: ["aerospace-askpass", "Password:"]),
            90: AskpassProcess(pid: 90, parentPid: 80, realUid: sudoRealUid, executablePath: sudoPath, arguments: ["sudo", "-A", "--", "/usr/bin/id", "-u"]),
            80: AskpassProcess(pid: 80, parentPid: 70, realUid: 501, executablePath: "/bin/zsh", arguments: ["zsh"]),
            70: AskpassProcess(pid: 70, parentPid: 1, realUid: 501, executablePath: "/opt/claude/claude", arguments: ["claude"]),
        ]
    }

    func testARealSudoRequestShowsTheCommandAndWhoAsked() {
        let t = table()
        let verdict = askpassVerdict(peerPid: 100, prompt: "Password:", ownUid: me) { t[$0] }
        XCTAssertEqual(verdict, .ask(AskpassRequest(
            prompt: "Password:", runAs: "root", command: ["/usr/bin/id", "-u"],
            requesters: ["zsh (80)", "claude (70)"], sudoPid: 90,
        )))
    }

    func testOnlySudoMayAsk() {
        let t = table(sudoPath: "/tmp/fake-sudo")
        guard case .refuse(let reason) = askpassVerdict(peerPid: 100, prompt: "", ownUid: me, lookup: { t[$0] }) else {
            return XCTFail("a non-sudo parent must not get a password panel")
        }
        XCTAssertTrue(reason.contains("only sudo"))
    }

    func testOtherUsersAreRefused() {
        let a = table(clientUid: 502)
        XCTAssertNotEqual(askpassVerdict(peerPid: 100, prompt: "", ownUid: me) { a[$0] }.isAsk, true)
        let b = table(sudoRealUid: 502)
        XCTAssertNotEqual(askpassVerdict(peerPid: 100, prompt: "", ownUid: me) { b[$0] }.isAsk, true)
        XCTAssertNotEqual(askpassVerdict(peerPid: 999, prompt: "", ownUid: me) { _ in nil }.isAsk, true)
    }

    func testNoPasswordWithoutTheCommand() {
        var t = table()
        t[90] = AskpassProcess(pid: 90, parentPid: 80, realUid: 501, executablePath: "/usr/bin/sudo", arguments: [])
        XCTAssertNotEqual(askpassVerdict(peerPid: 100, prompt: "", ownUid: me) { t[$0] }.isAsk, true, "unreadable command: refuse, never an empty panel")
    }

    func testSudoArgvParsing() {
        XCTAssertEqual(sudoCommand(["sudo", "-A", "--", "ls", "-la"]).command, ["ls", "-la"])
        XCTAssertEqual(sudoCommand(["sudo", "-A", "-u", "bob", "whoami"]).runAs, "bob")
        XCTAssertEqual(sudoCommand(["sudo", "-A", "-u", "bob", "whoami"]).command, ["whoami"])
        XCTAssertEqual(sudoCommand(["sudo", "-ubob", "-A", "id"]).runAs, "bob")
        XCTAssertEqual(sudoCommand(["sudo", "-A", "-p", "Pw:", "id", "-u"]).command, ["id", "-u"])
        XCTAssertEqual(sudoCommand(["sudo", "-A"]).command, [])
    }

    func testReplyRoundTrip() {
        XCTAssertEqual(AskpassReply.decode(AskpassReply.password("p@ss word").encoded), .password("p@ss word"))
        XCTAssertEqual(AskpassReply.decode(AskpassReply.refused("no\nnewlines").encoded), .refused("no newlines"))
        XCTAssertEqual(AskpassReply.decode(Data()), .refused("malformed reply from AeroSpace"))
        XCTAssertEqual(String(decoding: askpassEncodeRequest(prompt: "a\nb"), as: UTF8.self), "a b\n")
    }

    func testTheLabelNamesTheProgramNotTheShell() {
        XCTAssertEqual(askpassProgramName("/Users/x/.local/share/claude/versions/2.1.322"), "claude")
        XCTAssertEqual(askpassProgramName("/bin/zsh"), "zsh")
        XCTAssertEqual(askpassRequesterLabel(["zsh (80)", "2.1.322 (70)", "zsh (60)", "login (50)"]), "2.1.322")
        XCTAssertEqual(askpassRequesterLabel(["zsh (80)", "claude (70)"]), "claude")
        XCTAssertEqual(askpassRequesterLabel(["zsh (80)"]), "zsh")
        XCTAssertEqual(askpassRequesterLabel([]), "sudo")
    }

    func testCommandDisplayQuotes() {
        XCTAssertEqual(askpassDisplayCommand(["rm", "-rf", "/tmp/a b", "it's"]), "rm -rf '/tmp/a b' 'it'\\''s'")
    }

    func testTheKernelLookupReadsThisProcess() throws {
        let me = try XCTUnwrap(askpassLookupProcess(getpid()))
        XCTAssertEqual(me.parentPid, getppid())
        XCTAssertEqual(me.realUid, getuid())
        XCTAssertFalse(me.arguments.isEmpty)
    }

    func testThePanelNeverOpensUnderTest() async {
        Headless.resetForTests()
        let answer = await AskpassPanel.shared.ask(AskpassRequest(prompt: "", runAs: "root", command: ["id"], requesters: [], sudoPid: 1))
        XCTAssertNil(answer)
        XCTAssertEqual(Headless.blockedAttempts[.onScreenPanel], 1)
    }
}

private extension AskpassVerdict {
    var isAsk: Bool { if case .ask = self { true } else { false } }
}
