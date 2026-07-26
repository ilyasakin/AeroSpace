import Common
import Foundation

private struct ConfigFileWatcher: ~Copyable {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        fd = unsafe open(url.path, O_EVTONLY)
        if fd < 0 { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main,
        )
        source.setEventHandler { MainActor.checkIsolated { onChange() } }
        source.setCancelHandler { [fd] in close(fd) }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}

@MainActor private var currentWatcher: ConfigFileWatcher? = nil
@MainActor private var debounceTask: Task<Void, any Error>? = nil
@MainActor private var rearmTask: Task<Void, any Error>? = nil

private let debounceDelay: Duration = .milliseconds(200)
/// The watched path can be briefly absent mid-save (an atomic replace unlinks before renaming into
/// place), so a failed open is retried instead of being treated as "nothing to watch".
private let rearmRetryDelay: Duration = .milliseconds(200)
private let rearmAttempts = 5

@MainActor func syncConfigFileWatcher() {
    rearmTask?.cancel()
    rearmTask = nil
    currentWatcher = nil
    guard config.autoReloadConfig else { return }
    armConfigFileWatcher(attemptsLeft: rearmAttempts)
}

/// (Re)open the watch on `configUrl`.
///
/// The descriptor is bound to an **inode**, not to a path. Editors that save atomically — vim with
/// its default backupcopy, VS Code, TextEdit, anything that writes a temp file and renames it over
/// the target — replace that inode, so once `.rename`/`.delete` has fired the old descriptor
/// observes nothing ever again. The watch has to be rebuilt against the new file.
///
/// Rebuilding used to happen ONLY via `syncConfigFileWatcher` at the end of reload's apply block,
/// which a fatal parse error skips entirely. So an atomic save whose contents don't parse — by far
/// the most likely thing to be on disk while you are mid-edit — permanently killed auto-reload: you
/// fix the typo, save, and nothing happens again until AeroSpace restarts. The event handler now
/// re-arms unconditionally and before reloading, so a broken intermediate save cannot end the watch.
@MainActor private func armConfigFileWatcher(attemptsLeft: Int) {
    guard config.autoReloadConfig else { return }
    switch ConfigFileWatcher(url: configUrl, onChange: onConfigFileEvent) {
        case .some(let watcher):
            currentWatcher = consume watcher
        case .none:
            currentWatcher = nil
            guard attemptsLeft > 0 else { return }
            rearmTask = Task.startUnstructured {
                try await Task.sleep(for: rearmRetryDelay)
                armConfigFileWatcher(attemptsLeft: attemptsLeft - 1)
            }
    }
}

@MainActor private func onConfigFileEvent() {
    debounceTask?.cancel()
    debounceTask = Task.startUnstructured {
        try await Task.sleep(for: debounceDelay)
        // Re-arm BEFORE the reload and regardless of its outcome: the descriptor we were woken on
        // may already point at an unlinked inode, and a reload that fails to parse never reaches
        // the code that would otherwise rebuild the watch.
        armConfigFileWatcher(attemptsLeft: rearmAttempts)
        if let token: RunSessionGuard = .isServerEnabled {
            try await runLightSession(.configAutoReload, token) {
                _ = await reloadConfig_nonCancellable()
            }
        }
    }
}
