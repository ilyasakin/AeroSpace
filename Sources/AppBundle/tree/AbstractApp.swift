import Common

protocol AbstractApp: AnyObject, Hashable, AeroAny {
    var pid: Int32 { get }
    var rawAppBundleId: String? { get }

    @MainActor func getFocusedWindow(_ cm: CancellationMode) async throws -> Window?
    var name: String? { get }
    var execPath: String? { get }
    var bundlePath: String? { get }
    /// macOS "Hide" (cmd-H) state of the whole app
    @MainActor var isHidden: Bool { get }
}

extension AbstractApp {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.pid == rhs.pid {
            check(lhs === rhs)
            return true
        } else {
            check(lhs !== rhs)
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }
}

extension Window {
}
