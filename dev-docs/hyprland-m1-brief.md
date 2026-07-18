# M1 implementation brief — runtime Hyprland config compatibility

**Scope: M1 only.** M2–M5 are roadmap, see `dev-docs/hyprland-compatibility.md`. Do not implement
them here. Ship the day-one demo: **drop a real `hyprland.conf` at the config path, reload, and its
keybinds + dispatchers work live.**

File/line references are anchors — the tree is under active change, so **find the named symbol**,
don't trust line numbers.

## Decisions (RESOLVED — do not re-litigate)

- **Approach: whole-file-through-importer at load.** Detect config format at the read seam and route
  Hyprland-syntax text through the existing `importHyprConfig(...)` → TOML → `parseConfig`. **Do not**
  write a native `bind =` parser in M1. We accept the lossy TOML round-trip for now; a native parser
  is a later option only if the round-trip proves painful.
- Scratchpads, groups, master layout, `windowrulev2` new actions, borders, `hyprctl` are **out of
  scope for M1.**

## Guardrails (repo rules — non-negotiable)

- **No per-app hardcoded branches.** App-blind classification is a core project value; never
  reintroduce per-app special-casing.
- **No `Co-Authored-By: Claude` (or any AI) trailer** on commits in this repo.
- Adding a genuinely new command (new `CmdKind`) requires a `docs/aerospace-<name>.adoc` and a
  `./generate.sh` run (regenerates help/subcommand codegen) or it won't compile. **M1 needs no new
  `CmdKind`** — see T2.
- Match surrounding conventions; run `swiftformat` on touched files.
- `swift build` clean and `swift test` green (incl. new tests) before calling it done.
- Do not commit unless explicitly asked.

---

## T1 — Format detection + runtime routing (the core deliverable)

**Where:** `readConfig(forceConfigUrl:)` in `Sources/AppBundle/config/parseConfig.swift`, and the
reload path `reloadConfig_nonCancellable` in
`Sources/AppBundle/command/impl/ReloadConfigCommand.swift`. The single TOML entry today is
`parseConfig(_ rawToml:)` → `TOMLTable(source: rawToml)` — there is **no format detection anywhere**;
that is the net-new logic.

**Do:**
1. After reading the config file text, decide TOML vs Hyprland:
   - Primary: file extension — `.conf`/`.hypr` → Hyprland; `.toml` → TOML.
   - Fallback sniff for extension-less paths: treat as Hyprland if an early non-comment line matches
     Hyprland grammar (`bind* =`, `$name =`, `<section> {`) and there is no TOML table header/`key =`
     TOML shape. Keep the heuristic conservative — when unsure, default to TOML (current behavior).
2. If Hyprland: call `importHyprConfig(text, options)` (`Sources/AppBundle/config/importer/HyprImporter.swift`),
   take its emitted `.toml` string, and feed **that** to the existing `parseConfig`. The rest of the
   pipeline (hotkey (re)registration in `activateMode_nonCancellable`, `resetHotKeys`) is unchanged.
3. **Surface diagnostics.** `importHyprConfig` returns `ImportResult` with skip/failure diagnostics
   (`ImportDiagnostic.swift`). Merge these into the config warnings the user sees — do **not** drop
   them silently. A partially-translatable config must still load with the untranslatable lines
   reported.
4. Options: reuse `ImportConfigCmdArgs` defaults for `mod4Target` (SUPER→cmd vs alt). A sensible
   default is fine for M1; do not add new config surface for it yet.

**Acceptance:**
- A `hyprland.conf` at the config path, on `reload-config`, registers its `bind` keybindings live and
  they trigger the mapped commands.
- Unit test: a sample Hyprland config **string** run through the new routing produces a valid
  `Config` with non-empty `modes["main"].bindings`, and known-unsupported lines appear as warnings.
- Existing TOML configs are unaffected (regression: the full suite stays green).

## T2 — Dispatcher-name command surface (completes "usage" parity)

After T1, keybinds already work (the importer translates `bind` dispatchers). T2 makes the Hyprland
**verbs themselves** first-class so they work from the CLI and anywhere a command string is accepted
(`on-window-detected run`, `exec` chains), not only inside translated binds.

**Where:** `initSubcommands()` in `Sources/Common/cmdArgs/cmdArgsManifest.swift` — the single
command-name → parser table. Aliases are precedented here (`result["move-through"] = ...`,
`result["move-workspace-to-display"] = ...`). **No new `CmdKind` is needed** — an alias entry points a
Hyprland name at a parser that returns an **existing** `CmdArgs`; `toCommand()` dispatches on
`CmdKind`, so the invoked name is irrelevant to execution.

Two kinds of entry:
- **Pure alias** (identical arg grammar): one line, `result["<hyprname>"] = SubCommandParser(parseExistingCmdArgs)`.
- **Grammar-divergent** (Hyprland arg shape differs): write a small parser fn that normalizes Hypr
  args into the existing `CmdArgs`, register it under the Hyprland name. The normalization logic
  already exists in `HyprImporter.mapDispatcher` — port it, don't reinvent.

Note: aliases print the canonical name in `--help` and are absent from the CLI `SUBCOMMANDS` listing
(that comes from the `.adoc` codegen). Acceptable for M1; do not touch codegen.

### Dispatcher mapping table (this IS the T2 spec)

| Hyprland dispatcher | Hyprland args | Target command | Kind | Notes |
|---|---|---|---|---|
| `killactive` | — | `close` | alias | |
| `togglefloating` | — | `layout floating tiling` | divergent | toggles float/tile |
| `fullscreen` / `fullscreenstate` | — | `fullscreen` | alias | |
| `pin` | — | `sticky` | alias | |
| `centerwindow` | — | `center-window` | alias | |
| `togglesplit` | — | `split opposite` | divergent | |
| `movefocus` | `l/r/u/d` | `focus` | divergent | dir: `l→left … d→down` |
| `movewindow` | `l/r/u/d` | `move` | divergent | same dir map |
| `swapwindow` | `l/r/u/d` | `move` (or `swap`) | divergent | verify `swap` semantics vs `move` |
| `focusmonitor` | dir | `focus-monitor` | divergent | |
| `movecurrentworkspacetomonitor` | dir | `move-workspace-to-monitor` | divergent | |
| `resizeactive` | `X Y` (2 ints) | `resize width ±X` **+** `resize height ±Y` | divergent | grammar: `resize (smart\|smart-opposite\|width\|height) <val>`; emits two commands |
| `workspace` | `N` / `e±1`,`m±1`,`±1` / `previous` | `workspace N` / `workspace next\|prev` / `workspace-back-and-forth` | divergent | `special*` → unsupported (see below) |
| `movetoworkspace[silent]` | `N` | `move-node-to-workspace N` | divergent | `special*` → unsupported |
| `cyclenext` | — | `focus dfs-next` | divergent | |
| `submap` | name | `mode <name or main>` | divergent | |
| `exec` | cmd | `exec-and-forget <cmd>` | divergent | |

### Unsupported in M1 — emit a clear "no macOS equivalent" diagnostic, do NOT fake

`togglespecialworkspace`, `workspace special:*`, `movetoworkspace special:*` (→ M2), `pseudo`,
`splitratio` (use `resize`), `exit`, `movecursor*`, `forcerendererreload`, `dpms`, and any dispatcher
not in the table. These already fail in `mapDispatcher`; keep that behavior and make sure the
diagnostic reaches the user.

**Acceptance:**
- `aerospace movefocus l` behaves identically to `aerospace focus left`; `aerospace resizeactive 50 0`
  matches `resize width +50`. Add `parseCmdArgs` unit tests asserting each aliased/divergent name
  parses to the expected `CmdArgs`.
- No new `CmdKind`; no `generate.sh` needed; suite green.

---

## Definition of done (M1)

1. `swift build` clean; `swift test` green including new tests for T1 (hypr-string → valid Config)
   and T2 (dispatcher name → expected CmdArgs).
2. Demo works: a real `hyprland.conf`'s keybinds and the table's dispatcher verbs run live after
   `reload-config`.
3. Import diagnostics for untranslatable lines are surfaced, not swallowed.
4. No per-app branches; no AI co-author trailer; touched files swiftformat-clean.
5. TOML configs and the existing 469-test suite are unaffected.

## Explicitly deferred (so the implementer doesn't scope-creep)

Native `bind =` parser, special workspaces/scratchpad, master layout, groups/tab bar,
`windowrulev2` `size`/`move`/`opacity` actions, gradient borders, `hyprctl` — all later milestones.
