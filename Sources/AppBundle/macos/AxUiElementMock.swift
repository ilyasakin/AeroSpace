import AppKit
import Common

/// Alternative name: AttrAddressibleStorage
protocol AxUiElementMock {
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T?
    func containingWindowId() -> CGWindowID?
    /// nil means "unknown" (e.g. old AX dumps that don't carry writability info)
    func isSettable<Attr: WritableAttr>(_ attr: Attr) -> Bool?
}

extension AxUiElementMock {
    var cast: AXUIElement { self as! AXUIElement }
}
