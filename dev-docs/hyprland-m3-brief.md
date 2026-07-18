# M3 implementation brief — `windowrulev2` runtime + rule-action expansion

**Scope: M3 only.** Best after M1 (whole-file hypr routing gives runtime `windowrulev2` for the
already-translated subset); the net-new work here is **rule actions that have no command today**.
Roadmap: `dev-docs/hyprland-compatibility.md`. Anchors are symbol names.

## Background (what exists)

- `window-detection-rules` (`Sources/AppBundle/config/parseWindowDetectionRules.swift`) can only
  **classify**: `tile`/`float`/`ignore` (→ window/dialog/popup). Matchers: `app-id`,
  `app-name-regex-substring`, `window-title-regex-substring`, `window-subrole`, `window-level`,
  `during-aerospace-startup`. Applied first-match-wins in `MacApp.matchedWindowDetectionRule` /
  `resolveWindowType`.
- Richer behavior runs through `on-window-detected` callbacks (`parseOnWindowDetected.swift`,
  executed in `MacWindow.onWindowDetected`), which can run **any command** (`layout`,
  `move-node-to-workspace`, `sticky`, `fullscreen`, `center-window`, `resize`, …).
- The importer (`HyprImporter.handleWindowRule`) already translates `float`/`tile`/`pin`/`fullscreen`/
  `center`/`workspace N`. Everything else (`size`, `move`, `opacity`, `noanim`, …) is **skipped**.

## Decisions (RESOLVED)

- **Add the two geometry actions that have real macOS meaning: `size W H` (absolute px) and
  `move X Y` (absolute float placement).** These need **new commands** (none exist).
- **`opacity` is deferred to M4** (gated on the SkyLight-alpha spike).
- **`initialClass`/`initialTitle` are deferred** with a documented limitation: today title/class are
  read live at match time (`WindowDetectedCallback.matches`), so "initial" semantics aren't preserved.
  Folding them onto the live matchers (current behavior) is acceptable for M3; true first-seen capture
  is a follow-on.
- Visual-only actions (`noanim`, `noblur`, `noborder`, `rounding`, `bordercolor`, `noshadow`,
  `dimaround`, `xray`) are **not supported** — emit a clear diagnostic, never fake.

## Guardrails

No per-app branches; no AI co-author trailer; new `CmdKind` ⇒ `.adoc` + `./generate.sh`; swiftformat;
`swift build` + `swift test` green; don't commit unless asked.

---

## T1 — New geometry commands

**Where:** new commands under `Sources/AppBundle/command/impl/` + args under
`Sources/Common/cmdArgs/impl/`, registered in `CmdKind` (`cmdArgsManifest.swift` + `initSubcommands`)
and `toCommand()` (`cmdManifest.swift`). AX write path: `MacWindow.setAxFrame(topLeft:size:)` and the
floating layout helpers in `layoutRecursive.swift`/`layoutPersistent.swift`.

**Do:**
1. `resize-to <width> <height>` (absolute px on the focused/target window) — distinct from the
   existing relative/smart `resize`. For a **tiled** window, translate the pixel delta into a weight
   change (consistent with how `resize` mutates weights); for a **floating** window, set the AX size
   directly. Follow whatever `ResizeCommand` does for the tiled/floating split.
2. `move-to <x> <y>` — absolute placement for a **floating** window (set AX top-left). For a tiled
   window this is a no-op/float-first (match Hyprland: `move` implies floating placement); emit a
   diagnostic rather than silently ignoring.
3. Both must respect `--window-id`/target resolution like other commands, and update
   `lastAppliedLayoutPhysicalRect` appropriately so borders/reads stay consistent (see how
   `center-window` does it).

**Acceptance:** `resize-to 800 600` and `move-to 100 100` on a floating window set its AX frame; on a
tiled window they behave per the documented tiled semantics. Unit tests where geometry math is pure.
Suite green.

## T2 — Wire `windowrulev2` actions to commands

**Where:** `HyprImporter.handleWindowRule` (rule action translation) + `parseOnWindowDetected.swift`
(the vehicle for rule-triggered commands).

**Do:** extend the importer's action map so:
- `size W H` → on-window-detected `run = ["layout floating", "resize-to W H"]`
- `move X Y` → on-window-detected `run = ["layout floating", "move-to X Y"]`
- keep existing `float`/`tile`/`pin`/`fullscreen`/`center`/`workspace N`.
- unsupported actions → the existing skip diagnostic (make sure it reaches the user, not swallowed).

**Acceptance:** a `windowrulev2 = size 800 600, class:^(kitty)$` line imports to a working
on-window-detected rule that floats + sizes the matched window. Suite green.

## Definition of done (M3)

Build clean; suite green incl. geometry-command tests; importer translates `size`/`move`; unsupported
actions diagnosed. New commands have `.adoc` + codegen. No per-app branches; no AI co-author trailer.

## Explicitly deferred

`opacity` (M4 spike), `initialClass`/`initialTitle` first-seen capture, all compositor visual actions.
