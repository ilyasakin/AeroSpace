@testable import AppBundle
import AppKit
import Common

/// The test double for the macOS port: a simulated desktop.
///
/// Windows are plain records keyed by id. Frame writes land immediately and exactly (a real app
/// may clamp or lag — tests opt into that per window as the scenarios they need are added), focus
/// and raises are recorded, `close` makes the window vanish the way an app closing it would.
/// Production's frame, focus and parking logic runs unchanged on top of it.
@MainActor
final class SimulatedMacOS: MacOSPort {
    static let shared = SimulatedMacOS()
    private init() {}

    var frames: [UInt32: Rect] = [:]
    var titles: [UInt32: String] = [:]
    var fullscreen: Set<UInt32> = []
    var minimized: Set<UInt32> = []
    /// Windows whose app is too busy to answer native-state reads
    var nativeStateUnreadable: Set<UInt32> = []
    /// Last focus per window: `true` = with raise, `false` = without
    var lastFocusRaise: [UInt32: Bool] = [:]
    var onRaiseAndWait: ((UInt32) -> Void)?
    private(set) var frameWrites: [(windowId: UInt32, topLeft: CGPoint?, size: CGSize?)] = []

    func reset() {
        frames = [:]
        titles = [:]
        fullscreen = []
        minimized = []
        nativeStateUnreadable = []
        lastFocusRaise = [:]
        onRaiseAndWait = nil
        frameWrites = []
        windowTypes = [:]
        maxSize = [:]
        answersBeforeResizing = []
        aspectRatio = [:]
    }

    func axFrame(_ windowId: UInt32, _: CancellationMode) async throws -> Rect? { frames[windowId] }

    func axTitle(_ windowId: UInt32, _: CancellationMode) async throws -> String? {
        titles[windowId] ?? "TestWindow(\(windowId))"
    }

    func nativeState(_ windowId: UInt32, _: CancellationMode) async throws -> MacosNativeWindowState? {
        if nativeStateUnreadable.contains(windowId) { return nil }
        let isFullscreen = fullscreen.contains(windowId)
        return MacosNativeWindowState(isFullscreen: isFullscreen, isMinimized: !isFullscreen && minimized.contains(windowId))
    }

    /// Apps that won't go beyond a size (terminal/video style): the write lands clamped
    var maxSize: [UInt32: CGSize] = [:]
    /// Apps that resize asynchronously (Electron): they answer with the OLD frame, then get there
    var answersBeforeResizing: Set<UInt32> = []
    /// Apps that keep an aspect ratio (video): height follows width
    var aspectRatio: [UInt32: CGFloat] = [:]

    /// Lands immediately (clamped by `maxSize`) and answers synchronously, like an app that is
    /// never busy
    func writeFrame(_ windowId: UInt32, topLeft: CGPoint?, size: CGSize?, trailingSize _: Bool, onAnswer: @escaping @Sendable (Rect?) -> Void) {
        frameWrites.append((windowId, topLeft, size))
        let old = frames[windowId] ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        var width = size?.width ?? old.width
        var height = size?.height ?? old.height
        if let max = maxSize[windowId] {
            width = min(width, max.width)
            height = min(height, max.height)
        }
        if let ratio = aspectRatio[windowId] { height = min(height, width / ratio) }
        let landed = Rect(topLeftX: topLeft?.x ?? old.topLeftX, topLeftY: topLeft?.y ?? old.topLeftY, width: width, height: height)
        if answersBeforeResizing.contains(windowId) {
            onAnswer(Rect(topLeftX: landed.topLeftX, topLeftY: landed.topLeftY, width: old.width, height: old.height))
            frames[windowId] = landed
            return
        }
        frames[windowId] = landed
        onAnswer(landed)
    }

    func focus(_ windowId: UInt32) {
        lastFocusRaise[windowId] = true
        noteFocused(windowId)
    }

    func focusWithoutRaise(_ windowId: UInt32, previousKeyWindowId _: UInt32?) async -> Bool {
        lastFocusRaise[windowId] = false
        noteFocused(windowId)
        return true
    }

    private func noteFocused(_ windowId: UInt32) {
        guard let window = Window.get(byId: windowId) else { return }
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = window
    }

    func raise(_: UInt32) {}
    func raiseAndWait(_ windowId: UInt32) async { onRaiseAndWait?(windowId) }

    func close(_ windowId: UInt32) {
        // The app closes it and AeroSpace sees it gone: out of the registry and the tree
        guard let window = Window.get(byId: windowId) else { return }
        Window.registry.removeValue(forKey: windowId)
        window.unbindFromParent()
    }

    func setNativeFullscreen(_ windowId: UInt32, _ on: Bool) {
        if on { fullscreen.insert(windowId) } else { fullscreen.remove(windowId) }
    }

    /// Tests create their windows directly; there is nothing else on the simulated desktop
    func discoverWindows() async throws {}

    /// Per-window classification override (default: an ordinary window)
    var windowTypes: [UInt32: AxUiElementWindowType] = [:]
    func windowType(_ windowId: UInt32, level _: MacOsWindowLevel?, _: CancellationMode) async throws -> AxUiElementWindowType {
        windowTypes[windowId] ?? .window
    }
    func windowCountOfApp(ofWindow _: UInt32) async -> Int? { TestApp.shared.windows.count }
    func quitApp(ofWindow _: UInt32) -> Bool { false }
    func noteObservedNativeFocus(_: UInt32) {}
    var isScreenLocked = false
    var isOnFullscreenSpace = false
    func windowHasToolbar(_: UInt32) async -> Bool { false }

    func axFrameForTermination(_ windowId: UInt32) -> Rect? { frames[windowId] }
    func writeFrameForTermination(_ windowId: UInt32, topLeft: CGPoint, size: CGSize) {
        writeFrame(windowId, topLeft: topLeft, size: size, trailingSize: false) { _ in }
    }

    func setNativeMinimized(_ windowId: UInt32, _ on: Bool) {
        if on { minimized.insert(windowId) } else { minimized.remove(windowId) }
    }
}

/// The simulated desktop as WindowServer sees it (opt-in: `WindowServerReads.install(SimulatedWindowServer())`)
final class SimulatedWindowServer: WindowServerReadPort {
    func windowBounds(windowId: UInt32, forOverlay _: Bool) -> Rect? {
        MainActor.assumeIsolated { SimulatedMacOS.shared.frames[windowId] }
    }

    func onScreenSnapshot() -> OnScreenWindowSnapshot { OnScreenWindowSnapshot(levels: [:], normalStack: []) }
}
