import Common

/// Ring buffer of immutable world snapshots after structural changes.
///
/// Addresses #1215 motivation: cheap structural history for lock-screen recovery and
/// future undo / jump-to-workspace diagnostics. Live layout still mutates `TreeNode`;
/// each recorded entry is a path-copied persistent spine.
@MainActor
enum TreeHistory {
    private static var ring: [PersistentWorldSnapshot] = []
    private static let capacity = 32

    static var count: Int { ring.count }

    static var latest: PersistentWorldSnapshot? { ring.last }

    static func clear() {
        ring.removeAll(keepingCapacity: true)
    }

    /// Record a snapshot of the current live tree. No-op when the window set is empty
    /// (startup / empty session noise).
    static func recordLive() {
        let snap = PersistentWorldSnapshot.captureLive()
        if snap.windowIds.isEmpty && snap.workspaces.allSatisfy({ $0.rootTiling.windowIds.isEmpty }) {
            return
        }
        if let last = ring.last, last == snap {
            return // structural no-op
        }
        ring.append(snap)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        // Persist across AeroSpace restarts (apps stay open → window ids remain valid).
        SessionLayoutStore.scheduleSave()
    }

    /// All recorded generations (oldest first).
    static var generations: [PersistentWorldSnapshot] { ring }
}
