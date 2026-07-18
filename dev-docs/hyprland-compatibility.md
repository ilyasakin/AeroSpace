# Hyprland compatibility — product spec

## Thesis

Be the **Hyprland of macOS**: bring a Hyprland user's config, dispatchers, keybinds, window
rules, and CLI muscle memory to macOS as faithfully as the platform allows. Positioning is
*"your `hyprland.conf` and muscle memory, on macOS"* — **not** "Hyprland for macOS," because we are
a window manager on top of Aqua, not a compositor.

## The boundary that scopes everything

Hyprland owns rendering (it *is* the compositor). We move other apps' windows via AX/SkyLight; we
never composite them. Therefore:

| Achievable (usage / driving) | Not achievable (compositor / look) |
|------------------------------|-------------------------------------|
| dispatchers, keybinds, config syntax, window rules, workspaces, scratchpads, groups, CLI/IPC | smooth window move/resize/open/close **animations** on real app windows, **blur**, per-window **rounding** on arbitrary apps |
| eye-candy **we render ourselves**: gradient/glow/animated **borders**, group **tab bars**, HUDs | anything requiring us to draw another app's window content |

"Usage" is how it *drives*, not how it *looks*. That's the winnable 90%.

## Reframe: we have *import*, we need *compatibility*

Today `HyprImporter` (`Sources/AppBundle/config/importer/HyprImporter.swift`) **transpiles** a
`hyprland.conf` to AeroSpace TOML **offline** (`import-config` writes a `.toml`; never applied
live — `ImportConfigCommand.swift:63`). The runtime pipeline is unconditionally TOML
(`parseConfig.swift:249` hardcodes `TOMLTable(source:)`); there is **no format detection**. The
thesis upgrade is *runtime* parity: run a hypr-flavored config directly, dispatchers/rules behave
like Hyprland.

---

## Implementation briefs (handoff-ready work orders)

Each milestone has a self-contained brief — decisions resolved, integration points grounded, inlined
specs/tables, per-task acceptance criteria, and repo guardrails. Hand one brief to one agent.

| Milestone | Brief | Depends on |
|-----------|-------|-----------|
| M1 — runtime hypr config + dispatchers | [`hyprland-m1-brief.md`](hyprland-m1-brief.md) | — |
| M2 — master layout · scratchpad · groups · workspace rules | [`hyprland-m2-brief.md`](hyprland-m2-brief.md) | — (parallel to M1) |
| M3 — `windowrulev2` runtime + geometry actions | [`hyprland-m3-brief.md`](hyprland-m3-brief.md) | M1 (routing) |
| M4 — gradient/glow borders · tab bar · opacity spike | [`hyprland-m4-brief.md`](hyprland-m4-brief.md) | M2 (tab bar → groups) |
| M5 — `hyprctl`-style CLI/IPC | [`hyprland-m5-brief.md`](hyprland-m5-brief.md) | — |

Start with **M1** (day-one convert, low risk). M2 and M5 can run in parallel. This file is the
roadmap/context; the briefs are the work orders.

---

## Milestones (ROI order)

### M1 — Runtime Hyprland config + dispatcher + keybind compatibility  ← **start here**

**Goal:** paste your `hyprland.conf`, it works live — keybinds, dispatchers, `general` gaps/layout.
This is the highest-leverage "usage" parity and it turns the existing importer investment into a
live feature.

**1a. Runtime hypr-syntax config (cheapest path, reuses everything):**
- Add format detection at the config-read seam: `readConfig(forceConfigUrl:)`
  (`parseConfig.swift:24`) / `reloadConfig_nonCancellable` (`ReloadConfigCommand.swift:26`).
  Heuristic: file extension (`.conf` → hypr) or a leading-line sniff. **This is net-new logic —
  none exists.**
- If hypr-syntax, route text through `importHyprConfig(...).toml` → existing `parseConfig`. Reuses
  the entire translation *and* the untouched hotkey re-registration
  (`activateMode_nonCancellable`, `HotkeyBinding.swift:29`). One file changes; the risk surface is
  the detection heuristic only.

**1b. Dispatcher-name commands (so people type Hyprland verbs directly):**
Command name → parser is centralized in `initSubcommands()` (`cmdArgsManifest.swift:73`), and
**aliases are already precedented** (`move-through` → move at line 137; `move-workspace-to-display`
at 146). Two classes:
- *Pure aliases* (identical arg grammar): one line each in `initSubcommands()`.
  `killactive`→`close`, `centerwindow`→`center-window`, `pin`→`sticky`.
- *Different arg grammar* (`movefocus l` vs `focus left`, `resizeactive X Y`, `movewindow <dir>`):
  need a small dedicated parser fn that normalizes Hypr args to the target `CmdArgs` — the mapping
  already exists in `HyprImporter.mapDispatcher` (`HyprImporter.swift:223`); promote that logic
  from offline-translation to runtime parsers.
- Caveat: aliases only affect dispatch. `--help`/usage still print the canonical name
  (`parseCmdArgs.swift:55`), and aliases won't appear in the CLI `SUBCOMMANDS` list unless codegen
  is touched. Acceptable for M1.

**1c. Native `bind =` (only if not routing whole-file through 1a):** the grammar already exists —
`handleBind`/`mapBind` (`HyprImporter.swift:157/182`) produce exactly the
`(mode, "alt-shift-h", [commands])` tuples that `HotkeyBinding`/`parseBinding`/`parseCommand`
consume. For M1, prefer 1a (full-file translation) — least new code, same result.

**Files:** `parseConfig.swift` (detection seam), `ReloadConfigCommand.swift`, `cmdArgsManifest.swift`
(`initSubcommands` aliases), new `*CmdArgs.swift` parsers for grammar-divergent dispatchers,
`HyprImporter.swift` (promote `mapDispatcher` logic).

**Effort:** M — mostly wiring + promoting existing translation. **Risk:** low (format detection is
the only genuinely new logic).

---

### M2 — Layout & workspace behavior parity

**Master layout** (Hyprland's other default; we only have `tiles`/`accordion`/`dwindle`):
- Add `case master` to the single `Layout` enum (`TilingContainer.swift:58`) — it flows into both
  the live tree and the persistent spine automatically.
- Add `layoutPersistentMaster(...)` beside `layoutPersistentTiles`/`Accordion` and a `case .master:`
  branch at the layout switch (`layoutPersistent.swift:180`). Designate `children[0]` (or the MRU
  child) as the master area; lay the rest as a stack (reuse the tiles distribution for the stack
  rect). No separate "master slot" concept needed — index 0 is master.
- Wire `LayoutCmdArgs` (`LayoutCmdArgs.swift:26`), `LayoutCommand.run` (`LayoutCommand.swift:43`),
  `matchesDescription`, and `Config.defaultRootContainerLayout` (`Config.swift:42`).
- Capture/restore is generic over `Layout` — no bridge change. **Effort:** M. **Risk:** low-med.

**Special workspaces / scratchpad** (`togglespecialworkspace`):
- Honest constraint: **no overlay model exists.** AeroSpace shows exactly one workspace per monitor
  (`screenPointToVisibleWorkspace` is 1:1); `layoutWorkspaces()` parks every invisible workspace's
  windows off-screen via `hideInCorner` (`refresh.swift:132`, `MacWindow.hideInCorner:128`).
- Two implementable shapes:
  - **(a) Swap-and-toggle** (cheaper, recommended first): build on `SummonWorkspaceCommand` +
    `_prevFocusedWorkspaceName` (`focus.swift:107`) to bring a named workspace to the focused
    monitor and toggle back. Semantics = *swap*, not *overlay* — be upfront it's not a floating
    dropdown.
  - **(b) Sticky-floating scratchpad** (closer to Hyprland's overlay feel, more work): represent the
    special workspace's windows as sticky floating windows, parked in corner when hidden and
    centered when shown, reusing `hideInCorner`/`unhideFromCorner` + the sticky machinery
    (`StickyCommand.swift:42`).
- **Files:** new command modeled on `SummonWorkspaceCommand`, the visibility dicts in
  `Workspace.swift`, the hide/unhide loop in `refresh.swift:132`. **Effort:** M (a) / L (b).

**Window groups / tabbed** (`togglegroup`):
- Structure already exists: a group *is* an accordion `TilingContainer` (one tile, N stacked
  children, MRU front — `layoutPersistentAccordion:275`). `togglegroup` wraps/unwraps the focused
  tile in an accordion container (mirror the dwindle wrap at `MacWindow.swift:288`); cycling =
  focus next child + `markAsMostRecentChild`.
- The tab-bar *chrome* is deferred to **M4** (it needs an interactive overlay). M2 delivers group
  behavior without the visible tab strip. **Effort:** M (behavior).

**Workspace rules** (persistent, per-monitor, on-created-empty): partly exist —
`config.persistentWorkspaces` and `workspace-to-monitor-force-assignment`. Map Hyprland
`workspace = ...` rules onto these. **Effort:** S.

---

### M3 — `windowrulev2` runtime + rule-action expansion

Today rules are **import-time only**, and `window-detection-rules` can only *classify*
(`tile`/`float`/`ignore` — `parseWindowDetectionRules.swift`). Richer actions route through
`on-window-detected` running real commands (`MacWindow.swift:327`).

- Runtime `windowrulev2` comes largely free once M1a routes whole-file hypr configs through the
  importer (which already translates a rule subset — `handleWindowRule:298`).
- **Matchers:** `class`/`title` map cleanly (`app-id`/`app-name-regex-substring`,
  `window-title-regex-substring`). `initialClass`/`initialTitle` need capture-at-detection — today
  title is re-read live (`MacWindow.swift:364`), so "initial" semantics aren't preserved. **New.**
- **Actions needing NEW commands** (none exist today): `size W H` (absolute px), `move X Y` (float
  at coords). Add geometry commands under `command/impl/` + `Common/cmdArgs/`, invoked from
  callbacks.
- **Actions to drop honestly:** `opacity` (pending M4 spike), `noanim`/`noblur`/`rounding`/
  `bordercolor`/`noshadow` (compositor visual effects — no equivalent).
- **Files:** `parseWindowDetectionRules.swift`, `parseOnWindowDetected.swift`, `MacApp.swift:210`,
  `MacWindow.swift:256`, `HyprImporter.handleWindowRule`, new geometry commands. **Effort:** M-L.

---

### M4 — Signature eye-candy (the achievable Hyprland *look*)

**Gradient / glow / animated borders** — the single most iconic Hyprland visual, and it's ours to
render (we own the border overlay, already architected for this):
- Extend `WindowBorders` (`WindowBorders.swift`) from solid stroke to gradient/glow; map Hyprland
  `decoration { col.active_border = <gradient> }` onto border config. `decoration{}` currently has
  **no runtime target** (swallowed by the importer) — this milestone gives it one. **Effort:** M.

**Inactive-window opacity** (`active_opacity`/`inactive_opacity`):
- **Spike first:** does `SLSSetWindowAlpha` work on *other apps'* windows without elevated perms?
  If yes → a big "feels like Hyprland" win for low cost. If no → drop it honestly. **Effort:** S
  (spike) → M.

**Group tab bar** (pairs with M2 groups):
- New `NSPanelHud`-based overlay manager modeled on `WindowBordersManager` (`WindowBorders.swift:155`,
  driven from the refresh loop), positioned at the top of each accordion/group container's
  `lastAppliedLayoutPhysicalRect`, one tab per child. **Unlike borders it must accept clicks**
  (`ignoresMouseEvents = false`) and route to focus commands — a real departure from the purely
  decorative overlay. **Effort:** M-L.

---

### M5 — `hyprctl`-style IPC / CLI

- Map hyprctl query verbs (`clients`/`workspaces`/`monitors`/`activewindow`) onto existing `list-*`
  commands (already `isQueryOnly`, already JSON-capable via `--json` + `formatToJson.swift`).
- Add a global `-j` flag (today `--json` is per-command) in the CLI entry / `CmdArgsCommonState`.
- Add hyprctl-named aliases in `initSubcommands()`, or a pre-parse branch in `server.swift`
  analogous to the existing `subscribe` special-case. Response already travels JSON-wrapped in
  `ServerAnswer.stdout`. **Effort:** M. **Risk:** low.

---

## Explicitly out of scope (state upfront, avoids credibility damage)

- Smooth animated window transitions (move/resize/open/close) for real app windows — not a compositor.
- Blur, per-window corner rounding on arbitrary app windows.
- Compositor dispatchers: `dpms`, `forcerendererreload`, `movecursor*`, `exit`.
- `pseudo`-tiling; likely `nofocus`/`stayfocused`/`forceinput` focus-suppression (evaluate later).

## Sequencing

```
M1 (runtime config + dispatchers + keybinds)   ← day-one convert; demoable "paste your conf"
  → M2 (master layout, scratchpad, group behavior)
  → M4 borders (gradient/glow — the visual signature)
  → M3 rule actions + M5 hyprctl  (interleave)
  → M4 tab bar + opacity spike
```

M1 alone wins the Hyprland refugee. M4 borders is what makes screenshots read as Hyprland without
lying about being a compositor.

## First deliverable (concrete)

Ship **M1a + M1b**: format-detected runtime hypr config, plus the dispatcher-name surface. Demo:
drop a real `hyprland.conf` at the config path, reload, and the keybinds + `movefocus`/`resizeactive`/
`togglefloating`/`workspace`/`movetoworkspace` verbs work live. That single demo *is* the product's
reason to exist for the target audience.
