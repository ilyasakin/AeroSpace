# Product thesis — the Linux-WM compatibility layer for macOS

## One-liner (README hook)

> The macOS tiling window manager that runs your real Linux setup — your i3 or Hyprland config, and
> the i3 IPC protocol your tools already speak — unchanged.

## Identity: *compatible with*, not *inspired by*

Both competitors are inspired-by and make you learn their config:
- **AeroSpace** (our parent) is the i3-*inspired* macOS WM — own TOML config, own socket protocol.
- **OmniWM** is the Niri/Hyprland-*inspired* macOS WM — own `settings.toml`, own `omniwmctl`.

Our wedge is the thing neither does: **literal compatibility.** Bring your actual `~/.config/i3/config`
or `hyprland.conf` and it runs; point your existing i3-IPC tooling at us and it works. That
differentiates from *both* in one sentence and it's the honest justification for the fork (that, plus
being the maintained/open one — AeroSpace's maintainer is absent).

Do **not** re-theme as "more i3-flavored." That competes with the parent's core identity and is a thin
delta. The differentiator is compatibility as a *category*, spanning i3 **and** Hyprland — don't throw
away the Hyprland work (see `hyprland-compatibility.md`) to "become i3."

## What "compatibility" honestly means — and doesn't

| We are compatible with | We are NOT |
|------------------------|------------|
| i3/Hyprland **config** syntax (keybinds, modes, rules, gaps, workspace→output) | a compositor — no smooth animations/blur/rounding on real app windows |
| the **i3 IPC protocol** (wire format, requests, events) | able to run **Linux binaries** — polybar/i3status/i3blocks are X11/Linux programs, they don't run on macOS |
| the cross-platform **i3ipc client libraries** + scripts built on them, and `i3-msg` | a drop-in for X11-specific semantics (WM_CLASS, X11 window ids) — we map to the nearest macOS concept |

macOS-specific power (borders, per-monitor gaps, detection-rule tables, dwindle) is expressible only in
our native TOML — the Linux formats structurally can't hold it. That's fine: the Linux config runs for
what it expresses; the macOS extras live in TOML (or a small TOML sidecar).

## The three pillars

1. **Config dialects** (below). TOML native + i3 + Hyprland runtime dialects, format-detected.
2. **i3 IPC protocol server** — the flagship moat. See [`i3-ipc-brief.md`](i3-ipc-brief.md).
3. **First-party status bar** — kills the separate-plugin pain. See [`first-party-bar-brief.md`](first-party-bar-brief.md).

## Pillar 1 — Config architecture (decisions RESOLVED)

The internal `Config` model is the source of truth. There are multiple **surface dialects**,
format-detected at load (the seam already exists from Hyprland M1: `configFormat.swift` +
`readConfig` in `parseConfig.swift`):

- **TOML** — native, full-power. The *only* dialect that can express everything, including macOS-only
  features. Stays. We keep extending the model (and TOML) for new macOS features.
- **i3 config** — first-class **runtime** dialect (not just import): detect, translate to the model,
  run unchanged. Reuses the existing `I3Importer`.
- **Hyprland config** — already a runtime dialect (M1).

**Import is demoted, not deleted.** Plug-and-play (detect-and-run) replaces import as onboarding. The
translation *engine* stays — it's what powers the runtime dialects (the Hyprland path already routes
the file through the importer to the model at load). The user-facing `import-config` command survives,
**reframed as optional "eject to TOML"**: a one-time convert for users who want to go native and add
macOS-only settings. `create-react-app eject`, not the front door.

- **Onboarding:** zero steps — detect the config, run it. First-run flow becomes "Found your i3 config
  — use it directly," no generated file.
- **Diagnostics:** untranslatable lines still surface as load-time warnings (don't swallow).
- **macOS extras (RESOLVED default): TOML sidecar.** Literal i3/Hyprland config untouched + an
  optional small `aerospace.toml` overlay for borders/gaps/rules. Keeps the "unchanged config" promise
  strongest. (Inline extension directives in the Linux config is the rejected alternative — one file,
  but no longer a pristine config.)

## Guardrails (apply to every brief here)

- No per-app hardcoded branches (app-blind classification is a core value).
- No AI co-author trailer on commits.
- New `CmdKind` ⇒ `.adoc` + `./generate.sh`.
- `swift build` + `swift test` green; swiftformat touched files; don't commit unless asked.
- Be honest in docs/UX about the compatibility boundary above — never imply Linux binaries run on macOS.
