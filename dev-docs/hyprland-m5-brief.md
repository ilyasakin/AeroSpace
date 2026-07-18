# M5 implementation brief — `hyprctl`-style IPC / CLI

**Scope: M5 only.** Independent of the other milestones. Delivers a `hyprctl`-flavored query surface so
Hyprland scripting patterns and users' existing scripts feel at home. Roadmap:
`dev-docs/hyprland-compatibility.md`. Anchors are symbol names.

## Background (what exists)

- The `list-*` query commands already exist and are marked `isQueryOnly`
  (`Sources/Common/cmdArgs/cmdArgsManifest.swift`): `list-windows`, `list-workspaces`,
  `list-monitors`, `list-apps`, `list-modes`, `list-exec-env-vars`.
- JSON output already exists **per-command** via a `--json` flag (`ListWindowsCmdArgs.json`) using the
  generic serializer `Sources/AppBundle/command/formatToJson.swift` (`JSONEncoder.aeroSpaceDefault`).
- Transport: unix socket; command is the raw argv array in `ClientRequest`; response is
  `ServerAnswer { exitCode, stdout, stderr }` — JSON travels inside `stdout`. Server dispatch:
  `Sources/AppBundle/server.swift` (note the existing `subscribe` special-case as a precedent for a
  pre-parse branch). CLI client: `Sources/Cli/_main.swift`.
- Command-name → parser table: `initSubcommands()` (`cmdArgsManifest.swift`); aliases precedented
  (`move-through`).

## Decisions (RESOLVED)

- **Map hyprctl query verbs onto existing `list-*` commands via aliases** — do not build parallel
  query logic. `clients`→`list-windows`, `workspaces`→`list-workspaces`, `monitors`→`list-monitors`,
  `activewindow`→focused window (a filtered `list-windows`), `binds`→`list-modes` (or a new listing),
  `version`→existing version.
- **Add a global `-j`/`--json` flag** (today `--json` is per-command). It sets JSON output uniformly,
  reusing `formatToJson`.
- Keep the existing socket/`ServerAnswer` transport — JSON stays inside `stdout`. Do **not** invent a
  new wire protocol.

## Guardrails

No per-app branches; no AI co-author trailer; new `CmdKind` ⇒ `.adoc` + `./generate.sh` (aliases to
existing commands do **not** need a new `CmdKind`); swiftformat; `swift build` + `swift test` green;
don't commit unless asked.

---

## T1 — Global JSON flag

**Where:** the shared per-command state `CmdArgsCommonState` (`parseCmdArgs.swift`) or the CLI entry
`Sources/Cli/_main.swift`; the query-command `run` paths that already branch on `args.json`
(`ListWindowsCommand`, etc.).

**Do:** add a global `-j`/`--json` that, when present, forces JSON output on any command that supports
a listing, without requiring the per-command `--json`. Keep the per-command flag working. Reuse
`formatToJson` / `JSONEncoder.aeroSpaceDefault`; ensure output shape matches the existing `--json`.

**Acceptance:** `aerospace -j list-windows` == `aerospace list-windows --json`. Unit-test the global
flag parses and sets the JSON path. Suite green.

## T2 — hyprctl verb aliases

**Where:** `initSubcommands()` (`cmdArgsManifest.swift`).

**Do:** register hyprctl-named aliases pointing at the existing query parsers:
`clients`→list-windows, `workspaces`→list-workspaces, `monitors`→list-monitors. For `activewindow`,
add a tiny parser that produces a `ListWindowsCmdArgs` pre-filtered to the focused window (reuse
existing focus filters). Emit JSON by default for these verbs (hyprctl convention) or honor `-j`.

**Acceptance:** `aerospace clients -j` returns the same JSON as `list-windows --json`;
`aerospace activewindow -j` returns the focused window. Unit-test each alias parses to the expected
`CmdArgs`. Suite green.

## T3 (optional) — `hyprctl` umbrella shim

If you want literal `hyprctl <verb>` ergonomics: add a pre-parse branch in `server.swift`/the CLI
(mirror the `subscribe` special-case) that strips a leading `hyprctl` and dispatches the remaining
verb. Optional — the aliases in T2 already cover the muscle memory.

## Definition of done (M5)

Build clean; suite green incl. global-`-j` and alias parse tests; `clients`/`workspaces`/`monitors`/
`activewindow` return JSON matching the existing serializer. No new wire protocol. No per-app
branches; no AI co-author trailer.

## Explicitly deferred

Full hyprctl surface parity (keyword/setvar mutation verbs, `dispatch` batching), hyprctl's exact JSON
schema field-for-field — map to our schema, note differences.
