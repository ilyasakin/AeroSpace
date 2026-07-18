import Foundation

// MARK: - i3bar protocol (https://i3wm.org/docs/i3bar-protocol.html)

struct I3barHeader: Equatable, Sendable {
    var version: Int = 1
    var clickEvents: Bool = false
    var contSignal: Int? = nil
    var stopSignal: Int? = nil

    static func parse(_ object: [String: Any]) -> I3barHeader {
        I3barHeader(
            version: object["version"] as? Int ?? 1,
            clickEvents: (object["click_events"] as? Bool) ?? false,
            contSignal: object["cont_signal"] as? Int,
            stopSignal: object["stop_signal"] as? Int,
        )
    }
}

struct I3barBlock: Equatable, Sendable {
    var fullText: String
    var shortText: String?
    var color: String?
    var background: String?
    var minWidth: Int?
    var align: String?
    var name: String?
    var instance: String?
    var separator: Bool
    var separatorBlockWidth: Int?
    var border: String?
    var markup: String?

    static func parse(_ object: [String: Any]) -> I3barBlock {
        I3barBlock(
            fullText: object["full_text"] as? String ?? "",
            shortText: object["short_text"] as? String,
            color: object["color"] as? String,
            background: object["background"] as? String,
            minWidth: object["min_width"] as? Int,
            align: object["align"] as? String,
            name: object["name"] as? String,
            instance: object["instance"] as? String,
            separator: (object["separator"] as? Bool) ?? true,
            separatorBlockWidth: object["separator_block_width"] as? Int,
            border: object["border"] as? String,
            markup: object["markup"] as? String,
        )
    }
}

struct I3barClickEvent: Equatable, Sendable {
    var name: String?
    var instance: String?
    var button: Int
    var x: Int
    var y: Int

    func jsonLine() -> String {
        var d: [String: Any] = [
            "button": button,
            "x": x,
            "y": y,
        ]
        if let name { d["name"] = name }
        if let instance { d["instance"] = instance }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}

/// Incremental parser for i3bar protocol stdout.
/// Stream: optional `{header}\n` then infinite JSON array of status lines:
/// `[{block},…],\n[{block},…],\n…`
final class I3barProtocolParser: @unchecked Sendable {
    private var buffer = ""
    private(set) var header: I3barHeader?
    private var sawArrayStart = false

    /// Feed decoded stdout text. Returns newly completed status lines (arrays of blocks).
    func feed(_ chunk: String) -> [[I3barBlock]] {
        buffer += chunk
        var lines: [[I3barBlock]] = []

        if header == nil {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let end = firstCompleteJsonValueEnd(in: buffer) {
                let slice = String(buffer.prefix(end))
                if let data = slice.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    header = I3barHeader.parse(obj)
                    buffer = String(buffer.dropFirst(end))
                }
            }
        }

        buffer = dropLeadingWs(buffer)
        if !sawArrayStart, buffer.hasPrefix("[") {
            // Opening of the infinite array — only consume the first `[` if next non-ws is `[` (status line)
            // i3bar format: `[\n[{...}],\n[{...}]\n`
            sawArrayStart = true
            buffer.removeFirst()
            buffer = dropLeadingWs(buffer)
        }

        while true {
            buffer = dropLeadingWs(buffer)
            if buffer.hasPrefix(",") {
                buffer.removeFirst()
                buffer = dropLeadingWs(buffer)
            }
            guard buffer.hasPrefix("["), let end = firstCompleteJsonValueEnd(in: buffer) else {
                break
            }
            let slice = String(buffer.prefix(end))
            if let data = slice.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            {
                lines.append(arr.map { I3barBlock.parse($0) })
            }
            buffer = String(buffer.dropFirst(end))
        }
        return lines
    }

    func reset() {
        buffer = ""
        header = nil
        sawArrayStart = false
    }
}

private func dropLeadingWs(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Index past the end of the first complete JSON value (object or array) in `text`, or nil if incomplete.
func firstCompleteJsonValueEnd(in text: String) -> Int? {
    let chars = Array(text)
    var i = 0
    while i < chars.count, chars[i].isWhitespace { i += 1 }
    guard i < chars.count else { return nil }
    let start = chars[i]
    guard start == "{" || start == "[" else { return nil }

    var depth = 0
    var inString = false
    var escape = false
    while i < chars.count {
        let c = chars[i]
        if inString {
            if escape {
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString = false
            }
        } else {
            switch c {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
            }
        }
        i += 1
    }
    return nil
}
