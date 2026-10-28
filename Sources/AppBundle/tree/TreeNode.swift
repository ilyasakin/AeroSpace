import AppKit
import Common

open class TreeNode: Equatable, AeroAny {
    /// Stable identity for the node's lifetime. Snapshots of the tree carry it, so applying a
    /// transformed snapshot keeps the same container objects (their focus order, their rects,
    /// anything holding on to them) instead of rebuilding every container.
    final let nodeId: UInt64 = NodeIds.next()
    private var _children: [TreeNode] = []
    var children: [TreeNode] { _children }
    fileprivate final weak var _parent: NonLeafTreeNodeObject? = nil
    final var parent: NonLeafTreeNodeObject? { _parent }
    private var adaptiveWeight: CGFloat
    private let _mruChildren: MruStack<TreeNode> = MruStack()
    // Usages:
    // - resize with mouse
    // - makeFloatingWindowsSeenAsTiling in focus command
    var lastAppliedLayoutVirtualRect: Rect? = nil  // as if inner gaps were always zero

    /// **Intent.** What layout wants this node to occupy. Written by layout and by commands that
    /// deliberately override layout (`move-to`, `resize-to`). Read by anything reasoning about the
    /// grid: the layout diff baseline, drag/swap slots, tab-bar geometry, resize baselines.
    ///
    /// Intent only — what is KNOWN about a window's actual frame lives in its `FrameRecord`. The two
    /// used to alias one field (`lastAppliedLayoutPhysicalRect`), and layout records intent *before*
    /// it writes: the writer then read the new target back as "where the window already is",
    /// concluded the size was unchanged, and sent position only.
    var desiredRect: Rect? = nil { // with real inner gaps
        didSet { Kernel.noteModelMutation("desiredRect") }
    }


    final var unboundStacktrace: String? = nil
    var isBound: Bool { parent != nil } // todo drop, once https://github.com/nikitabobko/AeroSpace/issues/1215 is fixed

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.adaptiveWeight = adaptiveWeight
        bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    fileprivate init() {
        adaptiveWeight = 0
    }

    /// See: ``getWeight(_:)``
    func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        Kernel.noteModelMutation("setWeight")
        guard let parent else { die("Can't change weight if TreeNode doesn't have parent") }
        switch getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                if parent.orientation != targetOrientation {
                    die("You can't change \(targetOrientation) weight of nodes located in \(parent.orientation) container")
                }
                if parent.layout != .tiles && parent.layout != .master {
                    die("Weight can be changed only for nodes whose parent has 'tiles' or 'master' layout")
                }
                adaptiveWeight = newValue
            default:
                die("Can't change weight")
        }
    }

    /// Weight itself doesn't make sense. The parent container controls semantics of weight
    @MainActor
    func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        guard let parent else { die("Weight doesn't make sense for containers without parent") }
        return switch getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                parent.orientation == targetOrientation ? adaptiveWeight : parent.getWeight(targetOrientation)
            case .rootTilingContainer: parent.getWeight(targetOrientation)
            case .floatingWindow, .macosNativeFullscreenWindow: dieT("Weight doesn't make sense for floating windows")
            case .macosNativeMinimizedWindow: dieT("Weight doesn't make sense for minimized windows")
            case .macosPopupWindow: dieT("Weight doesn't make sense for popup windows")
            case .macosNativeHiddenAppWindow: dieT("Weight doesn't make sense for windows of hidden apps")
            case .shimContainerRelation: dieT("Weight doesn't make sense for stub containers")
        }
    }

    @MainActor
    @discardableResult
    func bind(to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        Kernel.noteModelMutation("bind")
        let result = unbindIfBound()

        if newParent === NilTreeNode.instance {
            return result
        }
        let relation = getChildParentRelation(child: self, parent: newParent) // Side effect: verify relation
        if adaptiveWeight == WEIGHT_AUTO {
            self.adaptiveWeight = switch relation {
                case .tiling(let newParent):
                    CGFloat(newParent.children.sumOfDouble { $0.getWeight(newParent.orientation) }).div(newParent.children.count) ?? 1
                case .floatingWindow, .macosNativeFullscreenWindow,
                     .rootTilingContainer, .macosNativeMinimizedWindow,
                     .shimContainerRelation, .macosPopupWindow, .macosNativeHiddenAppWindow:
                    WEIGHT_DOESNT_MATTER
            }
        } else {
            self.adaptiveWeight = adaptiveWeight
        }
        newParent._children.insert(self, at: index != INDEX_BIND_LAST ? index : newParent._children.count)
        _parent = newParent
        unboundStacktrace = nil
        // todo consider disabling automatic mru propogation
        // 1. "floating windows" in FocusCommand break the MRU because of that :(
        // 2. Misbehaved apps that abuse real window as popups https://github.com/nikitabobko/AeroSpace/issues/106 (the
        //    last appeared window, is not necessarily the one that has the focus)
        // Parking a window in a macOS-owned container (native fullscreen / hidden app / minimized /
        // popup) is not a focus event: marking it made that container the workspace's most-recent
        // child, so focus fallback picked parked tabs and fullscreen windows.
        if !newParent.isMacosParkingContainer {
            markAsMostRecentChild()
        }
        return result
    }

    private func unbindIfBound() -> BindingData? {
        guard let _parent else { return nil }

        let index = _parent._children.remove(element: self) ?? dieT("Can't find child in its parent")
        // Not every child is on the MRU stack: parking in a macOS container doesn't mark it
        _parent._mruChildren.remove(self)
        self._parent = nil
        unboundStacktrace = getStringStacktrace()

        return BindingData(parent: _parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    func markAsMostRecentChild() {
        guard let _parent else { return }
        _parent._mruChildren.pushOrRaise(self)
        _parent.markAsMostRecentChild()
    }

    var mostRecentChild: TreeNode? { _mruChildren.mostRecent ?? children.last }

    var mruChildren: MruStack<TreeNode> { _mruChildren }

    @discardableResult
    func unbindFromParent() -> BindingData {
        Kernel.noteModelMutation("unbind")
        return unbindIfBound() ?? dieT("\(self) is already unbound. The stacktrace where it was unbound:\n\(unboundStacktrace.prettyDescription)")
    }

    nonisolated public static func == (lhs: TreeNode, rhs: TreeNode) -> Bool {
        lhs === rhs
    }

    private var userData: [String: Any] = [:]
    func getUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData[key.key] as! T? }
    func putUserData<T>(key: TreeNodeUserDataKey<T>, data: T) {
        userData[key.key] = data
    }
    @discardableResult
    func cleanUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData.removeValue(forKey: key.key) as! T? }
}

// periphery:ignore - Generic T is used
struct TreeNodeUserDataKey<T> {
    let key: String
}

let WEIGHT_DOESNT_MATTER = CGFloat(-2)
/// Splits containers evenly if tiling.
///
/// Reset weight is bind to workspace (aka "floating windows")
let WEIGHT_AUTO = CGFloat(-1)

let INDEX_BIND_LAST = -1

struct BindingData {
    let parent: NonLeafTreeNodeObject
    let adaptiveWeight: CGFloat
    let index: Int
}

final class NilTreeNode: TreeNode, NonLeafTreeNodeObject {
    override private init() {
        super.init()
    }
    @MainActor static let instance = NilTreeNode()
}

enum NodeIds {
    private nonisolated(unsafe) static var last: UInt64 = 0
    /// Nodes are only ever created on the main thread
    static func next() -> UInt64 {
        unsafe last &+= 1
        return unsafe last
    }
}
