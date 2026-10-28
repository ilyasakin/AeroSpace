import AppKit
import Common

// The C callbacks each app's AXObserver invokes (registered in MacApp). They only translate the AX
// element into a window id and hand the event to the app-level handler — everything AeroSpace
// DOES about a notification lives above the port.

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxWindowListChanged(notif: notif as String)
}

func focusedWindowChangedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxFocusedWindowChanged(windowId: ax.containingWindowId(), notif: notif as String)
}

func titleChangedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxTitleChanged(windowId: ax.containingWindowId(), notif: notif as String)
}

func windowStateChangedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxNativeStateChanged(windowId: ax.containingWindowId(), notif: notif as String)
}

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxWindowMoved(windowId: ax.containingWindowId(), notif: notif as String)
}

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    onAxWindowResized(windowId: ax.containingWindowId(), notif: notif as String)
}
