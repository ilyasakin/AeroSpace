import CoreGraphics
import Foundation

@MainActor
private var cache: [UInt32: MacOsWindowLevel] = [:]
// Off-screen windows (minimized, parked in a corner, on another Space) never appear in the
// on-screen-only CGWindowList, so their lookups miss forever. Bound the full rescans to at most
// one per refresh session instead of one per miss
@MainActor
private var cacheIsFreshForCurrentRefreshSession = false

@MainActor
func invalidateWindowLevelCache() {
    cacheIsFreshForCurrentRefreshSession = false
}

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if let existing = cache[windowId] { return existing }
    if cacheIsFreshForCurrentRefreshSession { return nil }

    var result: [UInt32: MacOsWindowLevel] = [:]
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return nil }
    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        result[windowId] = .new(windowLevel: windowLayer)
    }
    cache = result
    cacheIsFreshForCurrentRefreshSession = true
    return result[windowId]
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
