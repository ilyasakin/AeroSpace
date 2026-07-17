import Common

extension Workspace {
    /// The tiling policy in effect: per-workspace override (tiling-policy command) wins over the config
    @MainActor var effectiveTilingPolicy: TilingPolicy {
        tilingPolicyOverride ?? config.tilingPolicy
    }
}
