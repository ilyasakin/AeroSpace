@testable import AppBundle
import AppKit

/// A model window backed by the simulated desktop (`SimulatedMacOS`). It overrides nothing: frame,
/// title, focus and native state all go through the macOS port exactly as in production. The
/// properties below are conveniences for arranging and inspecting the simulator's side.
final class TestWindow: Window, CustomStringConvertible {
    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let sim = SimulatedMacOS.shared
        sim.frames[id] = rect
        let wi = TestWindow(id, parent, adaptiveWeight)
        TestApp.shared._windows.append(wi)
        Window.registry[id] = wi
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor private var sim: SimulatedMacOS { SimulatedMacOS.shared }

    /// The window's frame on the simulated desktop (last written by layout; nil if never laid out)
    @MainActor var laidOutRect: Rect? { sim.frames[windowId] }

    /// Last focus: `true` raised, `false` focused without raise, nil if never focused
    @MainActor var lastNativeFocusRaise: Bool? { sim.lastFocusRaise[windowId] }

    @MainActor var titleForTest: String? {
        get { sim.titles[windowId] }
        set { sim.titles[windowId] = newValue }
    }

    @MainActor var isMacosFullscreenForTest: Bool {
        get { sim.fullscreen.contains(windowId) }
        set { if newValue { sim.fullscreen.insert(windowId) } else { sim.fullscreen.remove(windowId) } }
    }

    @MainActor var isMacosMinimizedForTest: Bool {
        get { sim.minimized.contains(windowId) }
        set { if newValue { sim.minimized.insert(windowId) } else { sim.minimized.remove(windowId) } }
    }

    /// Simulates an app too busy to answer AX (the native-state read fails)
    @MainActor var nativeStateUnreadableForTest: Bool {
        get { sim.nativeStateUnreadable.contains(windowId) }
        set { if newValue { sim.nativeStateUnreadable.insert(windowId) } else { sim.nativeStateUnreadable.remove(windowId) } }
    }

    /// Records awaited raises (ordering tests)
    @MainActor static var onNativeRaiseAndWait: ((UInt32) -> Void)? {
        get { SimulatedMacOS.shared.onRaiseAndWait }
        set { SimulatedMacOS.shared.onRaiseAndWait = newValue }
    }
}
