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

/// Border paint style: solid color, linear gradient, or glow (blurred expanded stroke).
enum BorderStyle: Equatable, Sendable {
    case solid(RgbaColor)
    case gradient(angleDegrees: Double, stops: [RgbaColor])
    case glow(RgbaColor, blurRadius: Double)

    var primaryColor: RgbaColor {
        switch self {
            case .solid(let c): c
            case .gradient(_, let stops): stops.first ?? RgbaColor(r: 0, g: 0, b: 0)
            case .glow(let c, _): c
        }
    }
}

struct WindowBorders: ConvenienceMutable, Equatable, Sendable {
    var enabled: Bool = false
    /// Border of the focused window
    var activeColor: RgbaColor = RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7) // pleasant blue
    /// Border of every other visible window
    var inactiveColor: RgbaColor = RgbaColor(r: 0x49, g: 0x4D, b: 0x64) // muted gray
    /// Extended style (gradient/glow). When nil, `activeColor`/`inactiveColor` solids are used.
    var activeStyle: BorderStyle? = nil
    var inactiveStyle: BorderStyle? = nil
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

    func resolvedActiveStyle() -> BorderStyle { activeStyle ?? .solid(activeColor) }
    func resolvedInactiveStyle() -> BorderStyle { inactiveStyle ?? .solid(inactiveColor) }
}

private let windowBordersParser: [String: any ParserProtocol<WindowBorders>] = [
    "enabled": Parser(\.enabled, parseBool),
    "active-color": Parser(\.activeColor, parseActiveColorField),
    "inactive-color": Parser(\.inactiveColor, parseInactiveColorField),
    "width": Parser(\.width, parseInt),
    "corner-radius": Parser(\.cornerRadius, parseInt),
    "corner-radius-overrides": Parser(\.cornerRadiusOverrides, parseCornerRadiusOverrides),
]

/// Parse solid / gradient / glow into activeColor + activeStyle
private func parseActiveColorField(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> RgbaColor {
    switch parseBorderStyle(raw, backtrace) {
        case .success(let style):
            // Store style on a side channel via mutating through parser is awkward; handle in parseWindowBorders
            return style.primaryColor
        case .failure(let err):
            c.errors.append(err)
            return WindowBorders().activeColor
    }
}

private func parseInactiveColorField(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> RgbaColor {
    switch parseBorderStyle(raw, backtrace) {
        case .success(let style):
            return style.primaryColor
        case .failure(let err):
            c.errors.append(err)
            return WindowBorders().inactiveColor
    }
}

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
    var borders = parseTable(raw, .disabled, windowBordersParser, backtrace, &c)
    // Re-parse color fields as full BorderStyle so gradients/glow are retained
    if let table = raw.asDictOrNil {
        if let active = table["active-color"], case .success(let style) = parseBorderStyle(active, backtrace + .key("active-color")) {
            borders.activeStyle = style
            borders.activeColor = style.primaryColor
        }
        if let inactive = table["inactive-color"], case .success(let style) = parseBorderStyle(inactive, backtrace + .key("inactive-color")) {
            borders.inactiveStyle = style
            borders.inactiveColor = style.primaryColor
        }
    }
    return borders
}

/// Parses a hex color string. Accepts:
/// - JankyBorders style `0xAARRGGBB` (alpha first) or `0xRRGGBB`
/// - CSS style `#RRGGBB` or `#RRGGBBAA` (alpha last)
/// - `gradient(<deg>deg, <color>, <color>, …)`
/// - `glow(<color>[, <blur>])`
func parseColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<RgbaColor> {
    parseBorderStyle(raw, backtrace).map(\.primaryColor)
}

func parseBorderStyle(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<BorderStyle> {
    parseString(raw, backtrace).flatMap { str in
        parseBorderStyleString(str).toResult(
            .init(backtrace, "Can't parse border style '\(str)'. Use hex color, gradient(...), or glow(...)"),
        )
    }
}

func parseBorderStyleString(_ str: String) -> BorderStyle? {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("gradient("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst("gradient(".count).dropLast())
        let parts = splitBorderStyleArgs(inner)
        guard let first = parts.first else { return nil }
        var angle = 0.0
        var colorParts = parts
        if first.lowercased().hasSuffix("deg"), let deg = Double(first.dropLast(3)) {
            angle = deg
            colorParts = Array(parts.dropFirst())
        }
        let colors = colorParts.compactMap(parseHexColor)
        guard colors.count >= 2 else { return nil }
        return .gradient(angleDegrees: angle, stops: colors)
    }
    if lower.hasPrefix("glow("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst("glow(".count).dropLast())
        let parts = splitBorderStyleArgs(inner)
        guard let first = parts.first, let color = parseHexColor(first) else { return nil }
        let blur = parts.count > 1 ? (Double(parts[1]) ?? 8) : 8
        return .glow(color, blurRadius: blur)
    }
    if let solid = parseHexColor(trimmed) {
        return .solid(solid)
    }
    return nil
}

private func splitBorderStyleArgs(_ inner: String) -> [String] {
    inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
