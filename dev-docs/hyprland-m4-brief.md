# M4 implementation brief — signature eye-candy (borders, tab bar, opacity)

**Scope: M4 only.** The achievable Hyprland *look* — the parts we render ourselves. Border work
depends on the existing `WindowBorders` overlay; the tab bar depends on M2 group behavior. Roadmap:
`dev-docs/hyprland-compatibility.md`. Anchors are symbol names.

## Decisions (RESOLVED)

- **Gradient/glow borders extend the existing overlay** (`Sources/AppBundle/ui/WindowBorders.swift`) —
  do not build a second border system. This is the single most iconic Hyprland visual and it's fully
  ours to render.
- **Opacity is spike-gated.** Do the SkyLight-alpha spike FIRST (T3). Only implement
  `active_opacity`/`inactive_opacity` if the spike proves it works on other apps' windows without
  elevated permissions. If it doesn't, drop it and document why — do not ship a half-working version.
- **Tab bar is a new interactive overlay** modeled on `WindowBordersManager`, but it accepts clicks
  (unlike the deliberately click-through borders).

## Guardrails

No per-app branches; no AI co-author trailer; new `CmdKind` ⇒ `.adoc` + `./generate.sh`; swiftformat;
`swift build` + `swift test` green; don't commit unless asked. SIP-disabling is not an option — any
SkyLight use must be SIP-free (only mutate windows we own, or read).

---

## T1 — Gradient / glow borders

**Where:** `Sources/AppBundle/ui/WindowBorders.swift` (`WindowBordersOverlay`, the per-window
`CAShapeLayer` in `BorderEntry`, `WindowBordersManager`), the border config struct
`Sources/AppBundle/config/parseWindowBorders.swift` (`WindowBorders`, `RgbaColor`), and the importer's
swallowed `decoration { }` block (`HyprImporter.swift` `swallowedSections`).

**Do:**
1. Extend the border color model from a single `RgbaColor` to a border *style*: solid | gradient
   (angle + stops) | glow. Keep solid as default; the struct already anticipated this.
2. Render gradient as a `CAGradientLayer` masked by the stroke path (or a stroked layer with a
   gradient fill), reusing the existing per-entry layer + occlusion mask so overlap behavior and the
   active-frontmost policy are unchanged. Glow = a blurred/expanded second stroke.
3. Parse Hyprland `decoration { col.active_border = <a> <b> ... Ndeg }` gradient syntax and
   `col.inactive_border` into the border style. Give `decoration` a runtime target (today it's
   dropped by the importer); wire the importer to emit the new border config instead of swallowing.

**Acceptance:** `window-borders.active-color` accepts a gradient spec and renders a gradient border;
a `hyprland.conf` `col.active_border` gradient imports and shows. Existing solid-border configs and
the border test suite are unaffected. Add a parse test for the gradient/glow config.

## T2 — Group tab bar (pairs with M2 groups)

**Where:** new overlay manager modeled on `WindowBordersManager` (`WindowBorders.swift`) over
`NSPanelHud` (`Sources/AppBundle/ui/NSPanelHud.swift`); driven from the refresh loop
(`Sources/AppBundle/layout/refresh.swift`), positioned at the top of each accordion/group container's
`lastAppliedLayoutPhysicalRect`.

**Do:**
1. New `NSPanelHud`-based overlay drawing one tab per child of each accordion/group container, active
   child highlighted (MRU front). Reconcile per-refresh exactly like `WindowBordersManager.refresh()`.
2. **Interactive:** `ignoresMouseEvents = false`; a click on a tab focuses that child (runs the focus
   command). This is the key departure from borders — route clicks to commands safely on the main
   actor.
3. Only render for containers that are actually groups (accordion); no chrome for plain tiles.

**Acceptance:** a group shows a tab strip; clicking a tab focuses that window; the strip tracks
focus/moves/resizes/workspace switches like borders do. Suite green; no regression to borders.

## T3 — Opacity spike, then (maybe) implement

**Where:** SkyLight bindings (`Sources/AppBundle/util/skyLight.swift`).

**Do:**
1. **Spike:** determine whether `SLSSetWindowAlpha`/equivalent can set the alpha of **another app's**
   window without elevated permissions / SIP changes. Time-box it. Report the finding in the PR.
2. If viable: add `active_opacity`/`inactive_opacity` config, applied per window on focus change
   (dim inactive, restore active), SIP-free. If not viable: remove the code, document the limitation
   in the roadmap, and move on. **Do not ship a flaky version.**

**Acceptance:** spike conclusion documented. If implemented: inactive windows dim per config and
restore on focus, with no crashes and no per-app special-casing.

## Definition of done (M4)

Build clean; suite green incl. gradient-config parse test; borders render gradient/glow; tab bar works
and is click-routable; opacity either works cleanly or is documented as dropped. No per-app branches;
no AI co-author trailer; SIP-free.

## Explicitly deferred

Animated border transitions timing curves beyond a simple glow pulse; blur/rounding of real windows
(impossible — not a compositor).
