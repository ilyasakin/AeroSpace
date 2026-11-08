@testable import AppBundle
import Common
import XCTest

final class AxWindowKindTest: XCTestCase {
    func test() throws {
        try checkAxDumpsRecursive(projectRoot.appending(path: "./axDumps"))
    }
}

func checkAxDumpsRecursive(_ dir: URL) throws {
    for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        if file.isDirectory {
            try checkAxDumpsRecursive(file)
            continue
        }
        if file.pathExtension == "md" { continue }

        let rawJson = try JSONSerialization.jsonObject(with: Data.init(contentsOf: file), options: [.json5Allowed]) as! [String: Any]
        let json = Json.newOrDieRecursive(rawJson).asDictOrDie
        let app = json["Aero.AXApp"]!.asDictOrDie
        let windowLevel = json["Aero.windowLevel"].map { MacOsWindowLevel.fromJson($0) ?? dieT() }
        let activationPolicy: NSApplication.ActivationPolicy = .from(string: rawJson["Aero.App.nsApp.activationPolicy"] as! String)
        assertEquals(
            json.getWindowType(
                axApp: app,
                activationPolicy,
                windowLevel,
                coversFullDisplay: rawJson["Aero.coversFullDisplay"] as? Bool ?? false,
                windowServerParentId: (rawJson["Aero.windowServerParentId"] as? NSNumber)?.uint32Value ?? 0,
            ),
            AxUiElementWindowType(rawValue: rawJson["Aero.AxUiElementWindowType"] as? String ?? dieT()),
            additionalMsg: "\(file.path()):0:0: AxUiElementWindowType doesn't match",
        )
    }
}

extension [String: Json]: AxUiElementMock {
    public func get<Attr>(_ attr: Attr) -> Attr.T? where Attr: ReadableAttr {
        guard let value = self[attr.key] else {
            return isSynthetic ? dieT("\(self) doesn't contain \(attr.key)") : nil
        }
        if let value = value.rawValue {
            return attr.getter(value as AnyObject)
                ?? dieT("Value \(value) (of type \(Swift.type(of: value))) isn't convertible to \(attr.key)")
        } else {
            return nil
        }
    }

    private var isSynthetic: Bool { self[kAXAeroSynthetic] != nil }

    public func isSettable<Attr>(_ attr: Attr) -> Bool? where Attr: WritableAttr {
        // Old dumps don't carry writability info -> unknown
        guard case .string(let writable)? = self["Aero.AxWritable"] else { return nil }
        return writable.split(separator: ",").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.contains(attr.key)
    }

    public func containingWindowId() -> CGWindowID? { _containingWindowId() }

    private func _containingWindowId() -> CGWindowID {
        let windowId = self["Aero.axWindowId"]?.asInt64OrNil ?? dieT()
        return UInt32.init(exactly: windowId).orDie()
    }
}

extension NSApplication.ActivationPolicy {
    static func from(string: String) -> NSApplication.ActivationPolicy {
        switch string {
            case "regular": .regular
            case "accessory": .accessory
            case "prohibited": .prohibited
            default: dieT("Unknown ActivationPolicy \(string)")
        }
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

final class WindowServerParentClassificationTest: XCTestCase {
    private func classify(_ dump: String, parent: UInt32) throws -> AxUiElementWindowType {
        let file = projectRoot.appending(path: "./axDumps/\(dump).json5")
        let rawJson = try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.json5Allowed]) as! [String: Any]
        let json = Json.newOrDieRecursive(rawJson).asDictOrDie
        return json.getWindowType(
            axApp: json["Aero.AXApp"]!.asDictOrDie,
            .from(string: rawJson["Aero.App.nsApp.activationPolicy"] as! String),
            json["Aero.windowLevel"].map { MacOsWindowLevel.fromJson($0) ?? dieT() },
            windowServerParentId: parent,
        )
    }

    /// A child window moves with its parent: never a tile
    func testAChildWindowIsNeverTiled() throws {
        assertEquals(try classify("apple_calendar", parent: 0), .window)
        assertEquals(try classify("apple_calendar", parent: 4242), .dialog)
        assertEquals(try classify("alacritty_decorations_buttonless", parent: 0), .window)
        XCTAssertNotEqual(try classify("alacritty_decorations_buttonless", parent: 4242), .window)
    }
}
