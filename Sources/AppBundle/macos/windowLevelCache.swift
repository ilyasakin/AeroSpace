import Foundation

/// Window levels come from the shared per-session CGWindowList snapshot
/// (see onScreenWindowSnapshot). Off-screen windows never appear in that list, so a miss after a
/// fresh scan is definitive for the rest of the session — not a reason to rescan.

@MainActor
func invalidateWindowLevelCache() {
    invalidateOnScreenWindowSnapshot()
}

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    onScreenWindowSnapshot().levels[windowId]
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
