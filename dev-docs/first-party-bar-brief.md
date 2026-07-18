# Brief — first-party status bar

**Scope: a WM-integrated status bar.** Context: `compatibility-thesis.md`. Kills the "separate plugin
tool" pain of SketchyBar — the bar ships with the WM, configured in the same config, and its common
modules *just work* with no plugin scripts. Anchors are symbol names.

## Why first-party is the differentiator

AeroSpace has **no** bar (its docs point you at SketchyBar). SketchyBar is a separate process with its
own config + shell-plugin ecosystem to wire up. A bar built into the WM, driven by WM state, with the
everyday modules built in, is real differentiation — and you already have the parts: the overlay render
infra (`NSPanelHud`, the `WindowBorders` / `GroupTabBar` CALayer overlays) and the workspace/mode/window
state (`TrayMenuModel.updateTrayText` already computes it for the tray).

## Decisions (RESOLVED)

- **v1 coexists *below* the macOS menu bar.** Do NOT fight the menu-bar-replacement / notch / hide-menu
  battle in v1 (that's what makes SketchyBar a big project). Coexist first; earn replacement later.
- **Common modules are built in and native** — no external process required for the everyday case.
- **The i3bar protocol is the extension contract** for everything else. The bar renders the protocol;
  it doesn't care what emitted it.
- **Do NOT fork the Linux status binaries** (i3status/i3blocks/i3status-rust). Porting them = rewriting
  their platform backends against IOKit/CoreAudio/etc. and owning multi-upstream forks forever — the
  messiest path for the least reused code. Instead: build common modules in, keep the protocol open,
  and *at most* own one thin i3blocks-style runner later (deferred).

## Architecture

- Per-monitor bar as an `NSPanelHud`-style overlay (reuse the borders/tab-bar infra), positioned below
  the system menu bar strip; driven from the refresh loop (like `WindowBordersManager.refresh()`) for
  WM-state modules, plus async updates from external module output.
- Interactive (clicks route to commands) — mirror the `GroupTabBar` interactive-overlay work, incl. the
  `hitTest`-passthrough lesson (empty regions must not eat clicks).

## Built-in modules (v1 — zero external process)

- **From WM state** (already computed in `TrayMenuModel`): workspaces (with focused/visible/urgent),
  binding mode, focused window/app. This is the SketchyBar pain solved — a workspace indicator that
  works out of the box.
- **Native system modules** via macOS APIs (no Linux binary): clock, battery (IOKit), CPU/memory
  (`host_statistics`/`sysctl`), network (SystemConfiguration/`getifaddrs`), volume (CoreAudio). These
  cover ~90% of what people put on a bar, so external status tools become *optional*.

## i3bar protocol input (the extension contract)

- Parse the i3bar protocol from a module's stdout: a header object
  `{version:1, click_events, cont_signal, stop_signal}` then an infinite JSON array of arrays of block
  objects (`{full_text, short_text, color, background, min_width, align, name, instance, separator,
  border, markup}`). Render blocks per those fields.
- **Bidirectional:** when `click_events` is set, send click events back to the module's stdin
  (`{name, instance, button, x, y, …}`). This is what makes i3blocks-style click actions work.
- Any i3bar-protocol emitter feeds the bar — portable shell scripts, a user's custom module, or a
  cross-platform generator. (Linux-native emitters still don't run on macOS — see the thesis.)

## Gotchas

- **Menu-bar coexistence / notch / per-monitor / Spaces + native fullscreen** — the hard 80%. v1
  scopes most of this out by coexisting below the menu bar; still handle per-monitor placement and
  reasonable behavior across Spaces (the border overlay already deals with `canJoinAllSpaces`).
- **Click routing** — reuse the `GroupTabBar` `hitTest` fix; the bar is interactive but must not eat
  clicks in empty regions.
- **Perf** — WM-state modules update on refresh events; external modules on their own cadence. Coalesce
  redraws (mirror the border overlay's `CFRunLoopObserver` coalescing).

## Acceptance (v1)

- A bar appears per monitor below the menu bar, showing live workspaces + mode + focused app from WM
  state, updating on switch with no external config.
- A native clock + battery module render.
- Piping a simple i3bar-protocol emitter into the bar renders its blocks; a click on a block with
  `click_events` sends the click back.

## Guardrails

No per-app branches; no AI co-author trailer; reuse overlay/render infra (don't build a second
overlay system); swiftformat; suite green; honest about Linux-binary limits.

## Deferred

Menu-bar replacement / hiding, notch handling, the one thin i3blocks-style runner + curated macOS
blocklet set, `GET_BAR_CONFIG` integration with the i3 IPC server.
