import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Registered production windows (a view of `Window.registry`)
    @MainActor static var allWindows: [MacWindow] { Window.registry.values.compactMap { $0 as? MacWindow } }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> Window {
        if let existing = Window.registry[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        let windowLevel = getWindowLevel(for: windowId)
        let windowType = try await macApp.resolveWindowType(windowId, windowLevel, .cancellable)

        return try await registerDiscoveredWindow(
            windowId: windowId,
            appBundleId: macApp.rawAppBundleId,
            frame: rect,
            windowType: windowType,
        ) { parent in
            MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }


    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }


}
