import Common

extension TreeNode {
    /// Finds the single child of the given type without allocating an intermediate array
    /// (unlike `children.filterIsInstance(of:)`). Dies if there is more than one
    @MainActor
    fileprivate func singleChild<T>(of _: T.Type) -> T? {
        var found: T? = nil
        for child in children {
            if let typed = child as? T {
                if found != nil { die("Expected zero or one \(T.self) child") }
                found = typed
            }
        }
        return found
    }
}

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        if let existing = singleChild(of: TilingContainer.self) { return existing }
        let orientation: Orientation = switch config.defaultRootContainerOrientation {
            case .horizontal: .h
            case .vertical: .v
            case .auto: workspaceMonitor.then { $0.width >= $0.height } ? .h : .v
        }
        return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout, index: INDEX_BIND_LAST)
    }

    @MainActor
    var floatingWindows: [Window] {
        floatingWindowsContainer.children.filterIsInstance(of: Window.self)
    }

    @MainActor
    var floatingWindowsContainer: FloatingWindowsContainer {
        singleChild(of: FloatingWindowsContainer.self) ?? FloatingWindowsContainer(parent: self)
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        singleChild(of: MacosFullscreenWindowsContainer.self) ?? MacosFullscreenWindowsContainer(parent: self)
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        singleChild(of: MacosHiddenAppsWindowsContainer.self) ?? MacosHiddenAppsWindowsContainer(parent: self)
    }

    @MainActor var forceAssignedMonitor: Monitor? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = sortedMonitors
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
            .first
    }
}
