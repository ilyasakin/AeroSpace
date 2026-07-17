import Common

/// A color as normalized RGBA components (0...1). Kept AppKit-free so Config stays Sendable;
/// the UI layer converts it to NSColor
struct RgbaColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From 8-bit components
    init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: Double(a) / 255)
    }
}

struct WindowBorders: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    /// Border of the focused window
    var activeColor: RgbaColor = RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7) // pleasant blue
    /// Border of every other visible window
    var inactiveColor: RgbaColor = RgbaColor(r: 0x49, g: 0x4D, b: 0x64) // muted gray
    var width: Int = 4
    var cornerRadius: Int = 10
    /// Per-app corner-radius overrides, keyed by app bundle id. macOS exposes no API to read a
    /// window's real corner radius, so apps whose rounding doesn't match `cornerRadius` get an
    /// explicit value here (and on recent macOS the radius even varies by window type)
    var cornerRadiusOverrides: [String: Int] = [:]

    static let disabled = WindowBorders()

    /// The corner radius to use for a window owned by `appId`: its override if any, else the default
    func cornerRadius(forAppId appId: String?) -> Int {
        if let appId, let override = cornerRadiusOverrides[appId] { return override }
        return cornerRadius
    }
}

private let windowBordersParser: [String: any ParserProtocol<WindowBorders>] = [
    "enabled": Parser(\.enabled, parseBool),
    "active-color": Parser(\.activeColor, parseColor),
    "inactive-color": Parser(\.inactiveColor, parseColor),
    "width": Parser(\.width, parseInt),
    "corner-radius": Parser(\.cornerRadius, parseInt),
    "corner-radius-overrides": Parser(\.cornerRadiusOverrides, parseCornerRadiusOverrides),
]

/// Parses a `{ "app.bundle.id" = <radius> }` table into per-app corner-radius overrides
func parseCornerRadiusOverrides(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: Int] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: Int] = [:]
    for (appId, rawRadius) in rawTable {
        if let radius = parseInt(rawRadius, backtrace + .key(appId)).getOrNil(appendErrorTo: &c.errors) {
            result[appId] = radius
        }
    }
    return result
}

func parseWindowBorders(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WindowBorders {
    parseTable(raw, .disabled, windowBordersParser, backtrace, &c)
}

/// Parses a hex color string. Accepts:
/// - JankyBorders style `0xAARRGGBB` (alpha first) or `0xRRGGBB`
/// - CSS style `#RRGGBB` or `#RRGGBBAA` (alpha last)
func parseColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<RgbaColor> {
    parseString(raw, backtrace).flatMap { str in
        parseHexColor(str).toResult(.init(backtrace, "Can't parse color '\(str)'. Use '0xAARRGGBB' (JankyBorders style) or '#RRGGBB[AA]'"))
    }
}

func parseHexColor(_ str: String) -> RgbaColor? {
    let lower = str.lowercased()
    let alphaFirst: Bool
    let hex: Substring
    if lower.hasPrefix("0x") {
        hex = lower.dropFirst(2)
        alphaFirst = true // JankyBorders: 0xAARRGGBB
    } else if lower.hasPrefix("#") {
        hex = lower.dropFirst()
        alphaFirst = false // CSS: #RRGGBBAA
    } else {
        return nil
    }
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    let chars = Array(hex)

    switch chars.count {
        case 6: // RRGGBB
            guard let r = Int(String(chars[0 ... 1]), radix: 16),
                  let g = Int(String(chars[2 ... 3]), radix: 16),
                  let b = Int(String(chars[4 ... 5]), radix: 16) else { return nil }
            return RgbaColor(r: r, g: g, b: b, a: 255)
        case 8:
            let vals = stride(from: 0, to: 8, by: 2).compactMap { Int(String(chars[$0 ... $0 + 1]), radix: 16) }
            guard vals.count == 4 else { return nil }
            return alphaFirst
                ? RgbaColor(r: vals[1], g: vals[2], b: vals[3], a: vals[0]) // AARRGGBB
                : RgbaColor(r: vals[0], g: vals[1], b: vals[2], a: vals[3]) // RRGGBBAA
        default:
            return nil
    }
}
