@testable import AppBundle
import XCTest

final class TomlPatcherTest: XCTestCase {
    let sample = """
        # AeroSpace config
        config-version = 2
        start-at-login = false # trailing comment
        accordion-padding = 30

        [gaps]
        inner.horizontal = 8
        inner.vertical = 8

        [gaps.outer]
        left = 4

        [mode.main.binding]
        alt-h = 'focus left'
        alt-enter = '''exec-and-forget osascript -e '
        tell application "Terminal" to activate
        \\''''

        [[on-window-detected]]
        if.app-id = 'com.example'
        run = 'layout floating'

        [[on-window-detected]]
        if.app-id = 'com.other'
        run = ['move-node-to-workspace X', 'layout tiling']
        """

    func testReplaceRootScalarPreservesTrailingComment() {
        let result = TomlPatcher.setValue(sample, table: [], key: "start-at-login", rawValue: "true")
        XCTAssertTrue(result.contains("start-at-login = true # trailing comment"))
        XCTAssertTrue(result.contains("# AeroSpace config"))
    }

    func testReplaceDottedKeyInsideTable() {
        let result = TomlPatcher.setValue(sample, table: ["gaps", "inner"], key: "horizontal", rawValue: "12")
        XCTAssertTrue(result.contains("inner.horizontal = 12"))
        XCTAssertTrue(result.contains("inner.vertical = 8"))
    }

    func testReplaceKeyInNestedTableHeader() {
        let result = TomlPatcher.setValue(sample, table: ["gaps", "outer"], key: "left", rawValue: "10")
        XCTAssertTrue(result.contains("left = 10"))
    }

    func testInsertMissingKeyIntoExistingTable() {
        let result = TomlPatcher.setValue(sample, table: ["gaps", "outer"], key: "right", rawValue: "6")
        let outerIdx = result.range(of: "[gaps.outer]")!.lowerBound
        let rightIdx = result.range(of: "right = 6")!.lowerBound
        let bindingIdx = result.range(of: "[mode.main.binding]")!.lowerBound
        XCTAssertTrue(outerIdx < rightIdx && rightIdx < bindingIdx)
    }

    func testInsertIntoMissingTableCreatesSection() {
        let result = TomlPatcher.setValue(sample, table: ["workspace-to-monitor-force-assignment"], key: "w1", rawValue: "'main'")
        XCTAssertTrue(result.contains("[workspace-to-monitor-force-assignment]\nw1 = 'main'"))
    }

    func testInsertRootKey() {
        let result = TomlPatcher.setValue(sample, table: [], key: "auto-reload-config", rawValue: "true")
        let insertedIdx = result.range(of: "auto-reload-config = true")!.lowerBound
        let gapsIdx = result.range(of: "[gaps]")!.lowerBound
        XCTAssertTrue(insertedIdx < gapsIdx)
    }

    func testReplaceMultilineBindingValue() {
        let result = TomlPatcher.setValue(sample, table: ["mode", "main", "binding"], key: "alt-enter", rawValue: "'exec-and-forget open -a Ghostty'")
        XCTAssertTrue(result.contains("alt-enter = 'exec-and-forget open -a Ghostty'"))
        XCTAssertFalse(result.contains("tell application"))
        XCTAssertTrue(result.contains("[[on-window-detected]]")) // sections after the multiline value survive
        XCTAssertTrue(result.contains("alt-h = 'focus left'"))
    }

    func testRemoveKey() {
        let result = TomlPatcher.removeKey(sample, table: ["mode", "main", "binding"], key: "alt-h")
        XCTAssertFalse(result.contains("alt-h"))
        XCTAssertTrue(result.contains("alt-enter"))
    }

    func testRemoveMultilineKey() {
        let result = TomlPatcher.removeKey(sample, table: ["mode", "main", "binding"], key: "alt-enter")
        XCTAssertFalse(result.contains("alt-enter"))
        XCTAssertFalse(result.contains("tell application"))
        XCTAssertTrue(result.contains("alt-h = 'focus left'"))
    }

    func testGetRawValue() {
        XCTAssertEqual(TomlPatcher.getRawValue(sample, table: [], key: "config-version"), "2")
        XCTAssertEqual(TomlPatcher.getRawValue(sample, table: ["mode", "main", "binding"], key: "alt-h"), "'focus left'")
        XCTAssertEqual(TomlPatcher.getRawValue(sample, table: ["gaps", "inner"], key: "vertical"), "8")
    }

    func testKeysListingInFileOrder() {
        let keys = TomlPatcher.keys(sample, table: ["mode", "main", "binding"])
        XCTAssertEqual(keys.map(\.key), ["alt-h", "alt-enter"])
        XCTAssertEqual(keys.first?.rawValue, "'focus left'")
    }

    func testReplaceArrayOfTables() {
        let newSections = [
            "[[on-window-detected]]\nif.app-id = 'com.new'\nrun = 'layout floating'\n",
        ]
        let result = TomlPatcher.replaceArrayOfTables(sample, name: "on-window-detected", sections: newSections)
        XCTAssertTrue(result.contains("if.app-id = 'com.new'"))
        XCTAssertFalse(result.contains("com.example"))
        XCTAssertFalse(result.contains("com.other"))
        XCTAssertTrue(result.contains("[mode.main.binding]")) // rest of doc intact
    }

    func testRemoveAllArrayOfTables() {
        let result = TomlPatcher.replaceArrayOfTables(sample, name: "on-window-detected", sections: [])
        XCTAssertFalse(result.contains("on-window-detected"))
        XCTAssertTrue(result.contains("[gaps]"))
    }

    func testSerializeString() {
        XCTAssertEqual(TomlPatcher.serialize(string: "focus left"), "'focus left'")
        XCTAssertEqual(TomlPatcher.serialize(string: "it's"), "\"it's\"")
        XCTAssertEqual(TomlPatcher.serialize(stringArray: ["a", "b"]), "['a', 'b']")
    }

    func testPatchedConfigStillParses() async {
        var text = sample
        text = TomlPatcher.setValue(text, table: [], key: "start-at-login", rawValue: "true")
        text = TomlPatcher.setValue(text, table: ["gaps", "inner"], key: "horizontal", rawValue: "20")
        text = TomlPatcher.setValue(text, table: ["mode", "main", "binding"], key: "alt-j", rawValue: "'focus down'")
        text = TomlPatcher.removeKey(text, table: ["mode", "main", "binding"], key: "alt-enter")
        let parsed = await parseConfig(text)
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        XCTAssertEqual(parsed.config.startAtLogin, true)
        XCTAssertEqual(parsed.config.gaps.inner.horizontal, .constant(20))
        XCTAssertNotNil(parsed.config.modes["main"]?.bindings["alt-j"])
    }
}
