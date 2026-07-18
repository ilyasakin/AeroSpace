# M2 implementation brief — layout & workspace behavior parity

**Scope: M2 only.** Depends on nothing in M1 (can proceed in parallel). Delivers: a **master** layout,
**special-workspace/scratchpad** toggling, **window-group** behavior, and **workspace rules**.
Roadmap context: `dev-docs/hyprland-compatibility.md`. Anchors are symbol names — the tree moves, so
find the symbol, don't trust line numbers.

## Decisions (RESOLVED — do not re-litigate)

- **Master layout = index-0-is-master.** `children[0]` fills the master area; the remaining children
  stack in the secondary area (reuse the tiles distribution for the stack). No separate "master slot"
  type. Configurable master *count* and *ratio* are **deferred** — single master, weight-driven ratio.
- **Scratchpad = swap-and-toggle**, NOT a floating overlay. AeroSpace shows one workspace per monitor;
  do not attempt to render two simultaneously. Build on `SummonWorkspaceCommand` semantics + a
  remembered previous workspace so a second invocation toggles back. Sticky-floating scratchpads are
  a **deferred** alternative.
- **Groups = behavior only in M2.** A group is an accordion `TilingContainer`; `togglegroup`
  wraps/unwraps. The visible **tab bar is M4** (it needs an interactive overlay). Do not build chrome
  here.

## Guardrails (repo rules — non-negotiable)

- No per-app hardcoded branches (app-blind classification is a core value).
- No AI co-author trailer on commits.
- New `CmdKind` ⇒ add `docs/aerospace-<name>.adoc` + run `./generate.sh` or it won't compile.
- Match conventions; `swiftformat` touched files; `swift build` + `swift test` green before done.
- Don't commit unless asked.

---

## T1 — Master layout

**Where:** the single `Layout` enum in `Sources/AppBundle/tree/TilingContainer.swift` (flows into both
the live tree and the persistent spine automatically); the geometry switch in
`Sources/AppBundle/layout/layoutPersistent.swift` (`layoutPersistentNode` → `switch layout` with
`.tiles`/`.accordion` cases); CLI in `Sources/Common/cmdArgs/impl/LayoutCmdArgs.swift`
(`LayoutDescription` enum, `parseLayoutDescription`) and `Sources/AppBundle/command/impl/LayoutCommand.swift`
(`run` switch, `matchesDescription`).

**Do:**
1. Add `case master` to `Layout`; handle it in `String.parseLayout()`.
2. Add `layoutPersistentMaster(...)` beside `layoutPersistentTiles`/`layoutPersistentAccordion`,
   signature-matched (orientation, children, point/width/height, virtual, context, mruWindowId), and a
   `case .master:` branch in the layout switch. Master = `children[0]`; lay the rest as a stack in the
   remaining rect — you may call the existing tiles distribution on the tail. Respect inner gaps and
   the fullscreen/`lastAppliedLayoutPhysicalRect`-diff write rules the other cases follow.
3. Wire `LayoutDescription` (`master`, optionally `h_master`/`v_master`), `LayoutCommand.run`,
   `matchesDescription`, and allow `Config.defaultRootContainerLayout` = master.
4. Capture/restore is generic over `Layout` — no `LiveTreeBridge` change.

**Acceptance:** `layout master` on a workspace with ≥2 tiled windows puts one in the master area and
stacks the rest; toggling back to `tiles` restores. Add a `layoutPersistentMaster` geometry unit test
(mirror `DwindleTilingTest`/existing layout tests): given N child weights + a rect, assert the master
rect and stack rects. Suite green.

## T2 — Special workspace / scratchpad (`togglespecialworkspace`)

**Where:** model on `Sources/AppBundle/command/impl/SummonWorkspaceCommand.swift`; the visibility
dictionaries + `getStubWorkspace` in `Sources/AppBundle/tree/Workspace.swift`; the previous-workspace
memory pattern `_prevFocusedWorkspaceName` in `Sources/AppBundle/focus.swift`
(see `WorkspaceBackAndForthCommand`); the park-off-screen loop `layoutWorkspaces()` +
`MacWindow.hideInCorner`/`unhideFromCorner` in `Sources/AppBundle/layout/refresh.swift`.

**Do:**
1. New command `toggle-special-workspace <name>` (new `CmdKind` → needs `.adoc` + `generate.sh`).
2. Behavior: if the named special workspace is **not** currently the focused monitor's active
   workspace, summon it (bring it to the focused monitor, parking the current one via the existing
   summon/stub path) and remember the workspace it replaced. If it **is** active, toggle back to the
   remembered workspace. This is *swap* semantics — one workspace visible per monitor at all times.
3. Wire the importer's currently-failing `togglespecialworkspace`, `workspace special:*`,
   `movetoworkspace special:*` cases (`HyprImporter.mapDispatcher`) to this command instead of
   emitting "unsupported".

**Acceptance:** binding `toggle-special-workspace scratch` twice shows then hides the scratch
workspace on the focused monitor. Unit-test the toggle bookkeeping (which name is active / remembered)
where it can be exercised without a live monitor. Suite green.

## T3 — Window groups behavior (`togglegroup`)

**Where:** the accordion container already exists (`Layout.accordion`, `layoutPersistentAccordion`);
mirror the dwindle wrap/unwrap logic in `Sources/AppBundle/tree/MacWindow.swift`
(`unbindAndGetBindingDataForNewTilingWindow`); MRU via `markAsMostRecentChild` in `TreeNode`.

**Do:**
1. New command `toggle-group` (new `CmdKind`): if the focused window's tile is not already an
   accordion group, wrap it (and, per Hyprland semantics, absorb the next-added window) in a new
   accordion `TilingContainer`; if it is, unwrap back to tiles. Reuse the container-wrap mechanics the
   dwindle path uses.
2. Add group-cycle commands or reuse existing focus within the accordion (`focus dfs-next`/prev +
   `markAsMostRecentChild`) so the accordion front changes. Map Hyprland `changegroupactive` onto this.
3. Map importer `togglegroup`/`changegroupactive` (currently unsupported) to these commands.

**Acceptance:** `toggle-group` on a tile converts it to a stacked accordion group and back; cycling
changes which member is frontmost. Unit-test the wrap/unwrap tree shape. **No tab bar** (M4). Suite
green.

## T4 — Workspace rules

**Where:** existing `config.persistentWorkspaces` (`Config.swift`) and
`workspace-to-monitor-force-assignment`; the importer's `workspace = ...` handling in `HyprImporter`.

**Do:** map Hyprland `workspace` rule directives that have equivalents — persistent
(`persistent:true` → `persistentWorkspaces`), per-monitor (`monitor:` → force-assignment),
default/on-created — onto the existing config surfaces. Rules with no equivalent
(`gapsin`/`gapsout` per-workspace, `decorate`, `rounding`) → clear diagnostic, don't fake.

**Acceptance:** a Hyprland `workspace = 1, monitor:DP-1, persistent:true` style rule imports to the
right force-assignment + persistence. Suite green.

## Definition of done (M2)

`swift build` clean; `swift test` green incl. new master-geometry, scratchpad-toggle, and group
wrap/unwrap tests. New commands have `.adoc` + regenerated codegen. No per-app branches; no AI
co-author trailer; swiftformat-clean.

## Explicitly deferred

Master count/ratio config; sticky-floating scratchpad; **group tab bar (M4)**; per-workspace visual
rules.
