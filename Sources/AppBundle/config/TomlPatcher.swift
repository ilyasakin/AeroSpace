import Foundation

/// Surgical editor for TOML config text. The Settings UI uses it to change individual values
/// in place, preserving the user's comments, ordering, and formatting everywhere else.
///
/// It deliberately understands only the TOML shapes that appear in aerospace configs:
/// - `[table.header]` and `[[array.of.tables]]` sections (bare or quoted, dotted path segments)
/// - `key = value` and `dotted.key = value` pairs (bare or quoted key segments)
/// - values: bare scalars, basic/literal strings (single and multi-line), arrays, inline tables
enum TomlPatcher {
    // MARK: - Public API

    /// Replaces the value of `table` + `key` with `rawValue` (an already serialized TOML value).
    /// The key is searched in every placement TOML allows: the exact `[table]` section,
    /// parent sections with a dotted key remainder, and the root region with the full dotted key.
    /// If the key doesn't exist, it's inserted into the deepest existing matching section,
    /// or a new `[table]` section is appended.
    static func setValue(_ text: String, table: [String], key: String, rawValue: String) -> String {
        let doc = Document(text)
        if let keyLine = doc.findKey(table: table, key: key) {
            let valueSpan = doc.valueSpan(startingAt: keyLine.valueStart)
            return String(text[text.startIndex ..< valueSpan.lowerBound]) + rawValue + String(text[valueSpan.upperBound...])
        }
        return insert(doc, text, table: table, key: key, rawValue: rawValue)
    }

    /// Removes `table` + `key` (including a multi-line value) if present.
    static func removeKey(_ text: String, table: [String], key: String) -> String {
        let doc = Document(text)
        guard let keyLine = doc.findKey(table: table, key: key) else { return text }
        let valueSpan = doc.valueSpan(startingAt: keyLine.valueStart)
        // Delete whole lines: from the start of the key's line through the end of the value's line
        let deleteStart = keyLine.lineStart
        var deleteEnd = valueSpan.upperBound
        if let newline = text[deleteEnd...].firstIndex(of: "\n") {
            deleteEnd = text.index(after: newline)
        } else {
            deleteEnd = text.endIndex
        }
        return String(text[text.startIndex ..< deleteStart]) + String(text[deleteEnd...])
    }

    /// Reads the raw (still TOML-serialized) value of `table` + `key`.
    static func getRawValue(_ text: String, table: [String], key: String) -> String? {
        let doc = Document(text)
        guard let keyLine = doc.findKey(table: table, key: key) else { return nil }
        let valueSpan = doc.valueSpan(startingAt: keyLine.valueStart)
        return String(text[valueSpan]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists the keys that resolve into `table`, in file order, with their raw values.
    static func keys(_ text: String, table: [String]) -> [(key: String, rawValue: String)] {
        let doc = Document(text)
        var result: [(String, String)] = []
        for region in doc.regions where !region.isArrayOfTables {
            guard region.path.count <= table.count, Array(table.prefix(region.path.count)) == region.path else { continue }
            let remainder = Array(table.dropFirst(region.path.count))
            for keyLine in region.keyLines {
                if keyLine.keyPath.count == remainder.count + 1, Array(keyLine.keyPath.prefix(remainder.count)) == remainder {
                    let span = doc.valueSpan(startingAt: keyLine.valueStart)
                    result.append((keyLine.keyPath.last!, String(text[span]).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        return result
    }

    /// Replaces every `[[name]]` section (and a root-level `name = [...]` array, if any)
    /// with `sections` (each an already serialized `[[name]]\nkey = value...` block).
    /// The new blocks go where the first old section was, or at the end of the document.
    static func replaceArrayOfTables(_ text: String, name: String, sections: [String]) -> String {
        var text = removeKey(text, table: [], key: name) // inline `name = [...]` form
        let doc = Document(text)
        let victims = doc.regions.filter { $0.isArrayOfTables && $0.path == [name] }
        let insertionPoint: String.Index = victims.first?.start ?? text.endIndex
        var insertionOffset = text.distance(from: text.startIndex, to: insertionPoint)
        for victim in victims.reversed() {
            if victim.start < insertionPoint {
                insertionOffset -= text.distance(from: victim.start, to: victim.end)
            }
            text.removeSubrange(victim.start ..< victim.end)
        }
        var block = sections.joined(separator: "\n")
        if !block.isEmpty {
            let at = text.index(text.startIndex, offsetBy: insertionOffset)
            if at == text.endIndex, !text.isEmpty, !text.hasSuffix("\n") { block = "\n" + block }
            if !block.hasSuffix("\n") { block += "\n" }
            text.insert(contentsOf: block, at: at)
        }
        return text
    }

    // MARK: - Value serialization

    static func serialize(string: String) -> String {
        if !string.contains("'") && !string.contains("\n") {
            return "'\(string)'"
        }
        if !string.contains("\n") {
            return "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
        }
        return "'''\n\(string)'''" // multi-line literal
    }

    static func serialize(stringArray: [String]) -> String {
        "[" + stringArray.map { serialize(string: $0) }.joined(separator: ", ") + "]"
    }

    static func serialize(bool: Bool) -> String { bool ? "true" : "false" }
    static func serialize(int: Int) -> String { String(int) }

    // MARK: - Document model

    private struct KeyLine {
        let keyPath: [String] // dotted key split into segments, quotes resolved
        let lineStart: String.Index
        let valueStart: String.Index // first index after '='
    }

    private struct Region {
        var path: [String] // [] for the root region
        var isArrayOfTables: Bool
        var start: String.Index // start of the header line ("" for root region -> startIndex)
        var end: String.Index // start of the next header line or endIndex
        var contentStart: String.Index // first index after the header line
        var keyLines: [KeyLine] = []
        var lastMeaningfulLineEnd: String.Index // end (incl. newline) of the last non-blank line
    }

    private struct Document {
        let text: String
        var regions: [Region] = []

        init(_ text: String) {
            self.text = text
            var current = Region(
                path: [],
                isArrayOfTables: false,
                start: text.startIndex,
                end: text.endIndex,
                contentStart: text.startIndex,
                lastMeaningfulLineEnd: text.startIndex,
            )
            var i = text.startIndex
            while i < text.endIndex {
                let lineEnd = text[i...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
                let line = text[i ..< lineEnd]
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") {
                    if let (path, isArray) = Self.parseHeader(trimmed) {
                        current.end = i
                        regions.append(current)
                        current = Region(
                            path: path,
                            isArrayOfTables: isArray,
                            start: i,
                            end: text.endIndex,
                            contentStart: lineEnd,
                            lastMeaningfulLineEnd: lineEnd,
                        )
                        i = lineEnd
                        continue
                    }
                }
                if !trimmed.isEmpty {
                    current.lastMeaningfulLineEnd = lineEnd
                }
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = Self.findAssignment(in: text, line: i ..< lineEnd) {
                    let rawKey = String(text[i ..< eq]).trimmingCharacters(in: .whitespaces)
                    if let keyPath = Self.parseKeyPath(rawKey) {
                        current.keyLines.append(KeyLine(keyPath: keyPath, lineStart: i, valueStart: text.index(after: eq)))
                    }
                }
                // Multi-line values: jump over the whole value so its lines aren't misparsed
                if let lastKey = current.keyLines.last, lastKey.lineStart == i {
                    let span = valueSpan(startingAt: lastKey.valueStart)
                    let afterValue = text[span.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
                    current.lastMeaningfulLineEnd = afterValue
                    i = afterValue
                    continue
                }
                i = lineEnd
            }
            current.end = text.endIndex
            regions.append(current)
        }

        func findKey(table: [String], key: String) -> KeyLine? {
            let target = table + [key]
            for region in regions where !region.isArrayOfTables {
                guard region.path.count <= target.count, Array(target.prefix(region.path.count)) == region.path else { continue }
                let remainder = Array(target.dropFirst(region.path.count))
                if let found = region.keyLines.first(where: { $0.keyPath == remainder }) {
                    return found
                }
            }
            return nil
        }

        /// The most specific existing non-array region whose path is a prefix of `table`
        func bestRegion(for table: [String]) -> Region? {
            regions
                .filter { !$0.isArrayOfTables && $0.path.count <= table.count && Array(table.prefix($0.path.count)) == $0.path }
                .max(by: { $0.path.count < $1.path.count })
        }

        /// The character range of the TOML value starting at (or after) `start`. Handles
        /// single/multi-line strings, arrays, inline tables, and bare scalars with trailing comments.
        func valueSpan(startingAt start: String.Index) -> Range<String.Index> {
            var i = start
            while i < text.endIndex, text[i] == " " || text[i] == "\t" { i = text.index(after: i) }
            let valueStart = i
            guard i < text.endIndex else { return valueStart ..< valueStart }

            func scanString(from: String.Index) -> String.Index { // returns index after the closing quote
                var j = from
                let quote = text[j]
                let isTriple = text[j...].hasPrefix(String(repeating: String(quote), count: 3))
                let delimiter = isTriple ? String(repeating: String(quote), count: 3) : String(quote)
                j = text.index(j, offsetBy: delimiter.count)
                while j < text.endIndex {
                    if quote == "\"", text[j] == "\\" {
                        j = text.index(j, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                    if text[j...].hasPrefix(delimiter) {
                        var end = text.index(j, offsetBy: delimiter.count)
                        // TOML allows ''''' (value ending with quotes). Absorb up to 2 extra quotes
                        if isTriple {
                            var extra = 0
                            while extra < 2, end < text.endIndex, text[end] == quote {
                                end = text.index(after: end)
                                extra += 1
                            }
                        }
                        return end
                    }
                    j = text.index(after: j)
                }
                return text.endIndex
            }

            switch text[i] {
                case "'", "\"":
                    return valueStart ..< scanString(from: i)
                case "[", "{":
                    let open = text[i], close: Character = text[i] == "[" ? "]" : "}"
                    var depth = 0
                    var j = i
                    while j < text.endIndex {
                        let ch = text[j]
                        if ch == "'" || ch == "\"" {
                            j = scanString(from: j)
                            continue
                        }
                        if ch == "#" { // comment inside a multi-line array
                            j = text[j...].firstIndex(of: "\n") ?? text.endIndex
                            continue
                        }
                        if ch == open { depth += 1 }
                        if ch == close {
                            depth -= 1
                            if depth == 0 { return valueStart ..< text.index(after: j) }
                        }
                        j = text.index(after: j)
                    }
                    return valueStart ..< text.endIndex
                default:
                    var j = i
                    while j < text.endIndex, text[j] != "\n", text[j] != "#" { j = text.index(after: j) }
                    // Trim trailing whitespace from the bare value
                    var end = j
                    while end > valueStart, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
                        end = text.index(before: end)
                    }
                    return valueStart ..< end
            }
        }

        /// Index of the `=` separating key and value on the line, quote-aware, or nil
        static func findAssignment(in text: String, line: Range<String.Index>) -> String.Index? {
            var i = line.lowerBound
            var inQuote: Character? = nil
            while i < line.upperBound {
                let ch = text[i]
                if let q = inQuote {
                    if ch == q { inQuote = nil }
                } else if ch == "'" || ch == "\"" {
                    inQuote = ch
                } else if ch == "=" {
                    return i
                } else if ch == "#" {
                    return nil
                }
                i = text.index(after: i)
            }
            return nil
        }

        /// "a.'b.c'.d" -> ["a", "b.c", "d"]; nil if malformed
        static func parseKeyPath(_ raw: String) -> [String]? {
            var result: [String] = []
            var i = raw.startIndex
            while i < raw.endIndex {
                while i < raw.endIndex, raw[i] == " " || raw[i] == "\t" { i = raw.index(after: i) }
                guard i < raw.endIndex else { return nil }
                let ch = raw[i]
                if ch == "'" || ch == "\"" {
                    let quote = ch
                    i = raw.index(after: i)
                    guard let close = raw[i...].firstIndex(of: quote) else { return nil }
                    result.append(String(raw[i ..< close]))
                    i = raw.index(after: close)
                } else {
                    var j = i
                    while j < raw.endIndex, raw[j] != ".", raw[j] != " ", raw[j] != "\t" { j = raw.index(after: j) }
                    let segment = String(raw[i ..< j])
                    guard !segment.isEmpty else { return nil }
                    result.append(segment)
                    i = j
                }
                while i < raw.endIndex, raw[i] == " " || raw[i] == "\t" { i = raw.index(after: i) }
                if i < raw.endIndex {
                    guard raw[i] == "." else { return nil }
                    i = raw.index(after: i)
                }
            }
            return result.isEmpty ? nil : result
        }

        /// "[a.b]" or "[[a.b]]" (already trimmed) -> path + isArrayOfTables; nil if not a header
        static func parseHeader(_ trimmed: String) -> (path: [String], isArray: Bool)? {
            var s = Substring(trimmed)
            var isArray = false
            guard s.hasPrefix("[") else { return nil }
            s = s.dropFirst()
            if s.hasPrefix("[") {
                isArray = true
                s = s.dropFirst()
            }
            guard let closeIdx = s.firstIndex(of: "]") else { return nil }
            let inner = s[s.startIndex ..< closeIdx].trimmingCharacters(in: .whitespaces)
            var rest = s[s.index(after: closeIdx)...]
            if isArray {
                guard rest.hasPrefix("]") else { return nil }
                rest = rest.dropFirst()
            }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
            guard let path = parseKeyPath(inner) else { return nil }
            return (path, isArray)
        }
    }

    // MARK: - Insertion

    private static func insert(_ doc: Document, _ text: String, table: [String], key: String, rawValue: String) -> String {
        // The root region is a valid insertion target only for root keys. For an absent
        // `[table]`, prefer creating the section over a root-level fully-dotted key
        if let region = doc.bestRegion(for: table), !region.path.isEmpty || table.isEmpty {
            let remainder = table.dropFirst(region.path.count) + [key]
            let line = remainder.map(quoteKeySegmentIfNeeded).joined(separator: ".") + " = " + rawValue + "\n"
            var at = region.lastMeaningfulLineEnd
            if at == text.startIndex, region.path.isEmpty, region.keyLines.isEmpty {
                // Empty root region: insert at the very beginning
                at = text.startIndex
            }
            var insertion = line
            if at > text.startIndex, text[text.index(before: at)] != "\n" {
                insertion = "\n" + insertion
            }
            var newText = text
            newText.insert(contentsOf: insertion, at: at)
            return newText
        }
        // No region matches: append a fresh section at the end
        var newText = text
        if !newText.isEmpty, !newText.hasSuffix("\n") { newText += "\n" }
        newText += "\n[" + table.map(quoteKeySegmentIfNeeded).joined(separator: ".") + "]\n"
        newText += quoteKeySegmentIfNeeded(key) + " = " + rawValue + "\n"
        return newText
    }

    static func quoteKeySegmentIfNeeded(_ segment: String) -> String {
        let bareAllowed = segment.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" }
        return bareAllowed && !segment.isEmpty ? segment : "'\(segment)'"
    }
}
