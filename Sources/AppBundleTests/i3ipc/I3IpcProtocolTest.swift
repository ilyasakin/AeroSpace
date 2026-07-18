@testable import AppBundle
import Common
import XCTest

final class I3IpcProtocolTest: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let payload = Data(#"{"success":true}"#.utf8)
        let frame = I3IpcFrame(message: .getVersion, payload: payload)
        var buf = i3IpcEncodeFrame(frame)
        assertEquals(buf.prefix(6), i3IpcMagic)
        assertEquals(buf.count, i3IpcHeaderSize + payload.count)

        switch i3IpcDecodeFrame(from: &buf) {
            case .success(let decoded):
                assertEquals(decoded.type, I3IpcMessageType.getVersion.rawValue)
                assertEquals(decoded.payload, payload)
                assertEquals(buf.count, 0)
            case .failure(let e):
                XCTFail("decode failed: \(e)")
        }
    }

    func testDecodeTruncated() {
        var buf = Data("i3-ipc".utf8)
        switch i3IpcDecodeFrame(from: &buf) {
            case .failure(.truncated): break
            default: XCTFail("expected truncated")
        }
    }

    func testDecodeBadMagic() {
        var buf = Data("xxxxxx".utf8) + Data(count: 8)
        switch i3IpcDecodeFrame(from: &buf) {
            case .failure(.badMagic): break
            default: XCTFail("expected badMagic")
        }
    }

    func testEventWireTypeHighBit() {
        let frame = I3IpcFrame(event: .workspace, payload: Data())
        assertTrue(frame.isEvent)
        assertEquals(frame.type, 0x8000_0000 | I3IpcEventType.workspace.rawValue)
    }

    func testWorkspaceNumRule() {
        assertEquals(i3WorkspaceNum(from: "3"), 3)
        assertEquals(i3WorkspaceNum(from: "3:web"), 3)
        assertEquals(i3WorkspaceNum(from: "12:foo"), 12)
        assertEquals(i3WorkspaceNum(from: "web"), -1)
        assertEquals(i3WorkspaceNum(from: "foo3"), -1)
        assertEquals(i3WorkspaceNum(from: ""), -1)
    }

    func testVersionPayloadShape() {
        let dict = i3IpcVersionPayload(productVersion: "1.2.3")
        assertEquals(dict["major"] as? Int, i3IpcCompatMajor)
        assertEquals(dict["minor"] as? Int, i3IpcCompatMinor)
        assertEquals(dict["patch"] as? Int, i3IpcCompatPatch)
        let human = dict["human_readable"] as? String ?? ""
        assertTrue(human.contains("AeroSpace"))
        assertTrue(human.contains("1.2.3"))
        assertTrue(human.contains("i3-ipc"))
    }

    func testWorkspaceDtoJson() {
        let dto = I3WorkspaceDTO(
            num: 3,
            name: "3:web",
            visible: true,
            focused: true,
            urgent: false,
            output: "Built-in Retina Display",
            rect: I3RectDTO(x: 0, y: 0, width: 1920, height: 1080),
        )
        let data = i3JsonData([dto.asDict])
        let arr = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        assertEquals(arr.count, 1)
        assertEquals(arr[0]["num"] as? Int, 3)
        assertEquals(arr[0]["name"] as? String, "3:web")
        assertEquals(arr[0]["focused"] as? Bool, true)
        let rect = arr[0]["rect"] as! [String: Any]
        assertEquals(rect["width"] as? Int, 1920)
    }
}

@MainActor
final class I3IpcCommandMapTest: XCTestCase {
    func testMapCommonVerbs() {
        assertEquals(i3MapCommandToAerospace("workspace 3"), "workspace 3")
        assertEquals(i3MapCommandToAerospace("workspace number 2"), "workspace 2")
        assertEquals(i3MapCommandToAerospace("focus left"), "focus left")
        assertEquals(i3MapCommandToAerospace("move right"), "move right")
        assertEquals(i3MapCommandToAerospace("kill"), "close")
        assertEquals(i3MapCommandToAerospace("fullscreen"), "fullscreen")
        assertEquals(i3MapCommandToAerospace("layout splith"), "layout tiles horizontal")
        assertEquals(i3MapCommandToAerospace("layout splitv"), "layout tiles vertical")
        assertEquals(i3MapCommandToAerospace("layout tabbed"), "layout accordion")
        assertEquals(i3MapCommandToAerospace("reload"), "reload-config")
        assertEquals(i3MapCommandToAerospace("move workspace 5"), "move-node-to-workspace 5")
        assertNil(i3MapCommandToAerospace("[class=\"Firefox\"] focus")) // Phase 2
    }

    func testSplitChain() {
        assertEquals(i3SplitCommandChain("workspace 1; focus left"), ["workspace 1", "focus left"])
    }

    func testSplitChainRespectsQuotes() {
        // Semicolons inside exec strings must not split the chain.
        assertEquals(
            i3SplitCommandChain(#"exec "echo a; echo b"; workspace 2"#),
            [#"exec "echo a; echo b""#, "workspace 2"],
        )
        assertEquals(
            i3SplitCommandChain("exec 'foo; bar'; kill"),
            ["exec 'foo; bar'", "kill"],
        )
    }
}
