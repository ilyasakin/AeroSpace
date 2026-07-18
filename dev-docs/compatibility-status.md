# Compatibility stack status

Implements the three pillars from [`compatibility-thesis.md`](compatibility-thesis.md).

## Pillar 1 — Config dialects

| Dialect | Runtime load | Notes |
|---------|--------------|--------|
| TOML | Yes | Native, full power |
| Hyprland | Yes (M1) | `.conf`/`.hypr` + sniff → `importHyprConfig` |
| i3 | Yes | Path (`…/i3/config`) + sniff → `importI3Config` |

- **Discovery:**
  1. `~/.aerospace.toml` → full native primary (if present)
  2. else i3/Hyprland config → primary (plug-and-play)
  3. else `~/.config/aerospace/aerospace.toml` → native primary
- **Sidecar (overlay-wins):** When primary is i3/Hyprland, `~/.config/aerospace/aerospace.toml` is **not** the primary — it merges on top for macOS extras (borders, bar, …). Settings writes this file.
- **`import-config`:** Optional eject to TOML (first-run “Eject…” or CLI).

## Pillar 2 — i3 IPC (Phase 1)

- Separate socket: `/tmp/<appId>-<user>-i3.sock` (`i3IpcSocketPath`), framing per i3-ipc(7).
- `$I3SOCK` injected into exec environments.
- Handlers: `GET_VERSION`, `GET_WORKSPACES`, `GET_OUTPUTS`, `RUN_COMMAND` (common verbs), `SUBSCRIBE` (`workspace`, `window`).
- CLI: `aerospace i3-msg`, `aerospace i3-socket-path` (no binary named `i3` by default).
- Version: i3-compat API 4.22.0 + `human_readable: AeroSpace <ver> (i3-ipc compatible)`.
- Workspace `num` rule: leading digits or `-1`.

**Not shipped:** polybar/i3status/i3bar on macOS, GET_TREE / criteria selectors (Phase 2).

## Pillar 3 — First-party bar (v1)

**Settings UI (preferred):** AeroSpace → Settings… → **General → Status bar**  
Toggle on/off, height, modules, colors, optional external status command. Edits native TOML (or the sidecar when the live primary is i3/Hyprland) and reloads live.

Opt-in TOML (same keys the Settings GUI writes):

```toml
[bar]
enabled = true
modules-left = ['workspaces', 'mode', 'focused']
modules-right = ['clock', 'battery']
# hide-empty-workspaces = true  # omit unoccupied spaces (focused always shown)
# status-command = ['/path/to/i3bar-protocol-emitter']
```

- Per-monitor strip **below** the system menu bar (no menu-bar replacement).
- Built-ins: workspaces (click → focus; optional hide-empty), mode, focused app, clock, battery, cpu, memory.
- i3bar protocol input + click_events → module stdin.
- Hit-test passthrough on empty regions.

## Honesty boundary

Linux status binaries do **not** run on macOS. The moat is config dialects + i3 IPC + first-party bar / portable i3bar emitters.
