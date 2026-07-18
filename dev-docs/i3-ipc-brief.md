# Brief — i3 IPC protocol server (the flagship moat)

**Scope: the i3 IPC server.** Context: `compatibility-thesis.md`. This is the differentiator neither
AeroSpace nor OmniWM has: speak i3's wire protocol so the cross-platform i3 tooling ecosystem drives
our WM. Anchors are symbol names — find the symbol, don't trust line numbers.

## Honest scope (RESOLVED — do not oversell)

What this delivers, precisely:
- The **i3 IPC wire protocol** over a Unix socket.
- The cross-platform **i3ipc client libraries** (Python `i3ipc`, Go `go-i3`, Rust `i3ipc`) and the
  **scripts/automation** built on them — these run on macOS and will drive the WM.
- An **`i3-msg`-compatible** command surface.
- **Driving a macOS bar** (our first-party bar, or SketchyBar/Übersicht) from an i3ipc script.

What this does **NOT** deliver (state it in docs):
- **polybar / i3status / i3blocks / i3bar do not run on macOS** — they're X11/Linux binaries. The moat
  is the protocol + libraries + scripts, not "your Linux bar on macOS." Never imply otherwise.

## Wire protocol (verify against `i3-ipc(7)` / the i3 IPC reference before coding)

- Unix socket. Framing: magic string `i3-ipc` (6 bytes) + `payload-length` (u32) + `message-type`
  (u32) + JSON payload. Same framing for replies.
- **Events** are pushed frames with the high bit set on the type (`0x80000000 | event-number`).
- Message types (numbers per i3): `RUN_COMMAND=0`, `GET_WORKSPACES=1`, `SUBSCRIBE=2`, `GET_OUTPUTS=3`,
  `GET_TREE=4`, `GET_MARKS=5`, `GET_BAR_CONFIG=6`, `GET_VERSION=7`, `GET_BINDING_MODES=8`,
  `GET_CONFIG=9`, `SEND_TICK=10`, `SYNC=11`.
- Event numbers: `workspace=0`, `output=1`, `mode=2`, `window=3`, `barconfig_update=4`, `binding=5`,
  `shutdown=6`, `tick=7`.

Build it as a **separate socket** with i3 framing — do not overload our own `ServerAnswer` protocol
(`server.swift` / `clientServer.swift`). Reuse the socket *infrastructure pattern* (NWListener,
length-prefixed reads) and put the path next to `socketPath` in `commonUtil.swift`.

## Socket discovery (RESOLVED)

Linux tools find the socket via `$I3SOCK`, `i3 --get-socketpath`, or an X11 root-window atom. **No X11
on macOS**, so:
- Set `$I3SOCK` in the environment of anything we launch (e.g. `exec_always` from the config).
- Ship an `i3` shim (or `aerospace`-provided subcommand symlinkable as `i3`) that answers
  `--get-socketpath`. Caveat: a binary literally named `i3` in PATH — make it opt-in.

## Phase 1 — the bar-critical subset (ship first, demoable)

Implement: `GET_VERSION`, `GET_WORKSPACES`, `GET_OUTPUTS`, `RUN_COMMAND` (basic command strings),
`SUBSCRIBE` to `workspace` and `window` events. This alone makes i3ipc-library scripts and `i3-msg`
work and can drive a bar.

JSON mappings from our model (source of truth = the live tree / `Workspace` / `Monitor`, the same state
`TrayMenuModel` already computes):
- **GET_WORKSPACES** → array of `{num, name, visible, focused, urgent, output, rect}`. **Gotcha
  (RESOLVED):** our workspaces are string-named, i3's `num` is an integer — emit the numeric prefix as
  `num` when the name is numeric, else `num: -1` (i3's convention for named workspaces). This is the #1
  spot that trips real tools; test it.
- **GET_OUTPUTS** → monitors as `{name, active, primary, rect, current_workspace}`.
- **GET_VERSION** → `{major, minor, patch, human_readable}` — pick a version string that satisfies
  version-gating tools.
- **RUN_COMMAND** → parse the i3 command string, map to our commands, return `[{success: true/false}]`
  per command. Phase 1: support the common verbs (`workspace N`, `focus <dir>`, `move …`,
  `layout …`, `fullscreen`, `kill`). Full grammar + `[criteria]` selectors are Phase 2.
- **SUBSCRIBE**: after subscribing, push `workspace` events (`{change: focus|init|empty|rename|move,
  current, old}`) and `window` events (`{change: new|close|focus|title|move|floating|fullscreen_mode,
  container}`) as our transitions happen. **Ordering/latency matter** — emit workspace-focus before
  window-focus, promptly, or bars flicker.

**Acceptance (Phase 1):** a Python `i3ipc` script connects via `$I3SOCK`, `GET_WORKSPACES` returns the
live workspaces with correct `num`, `SUBSCRIBE(["workspace"])` streams events on switch, `i3-msg
'workspace 3'` switches. Unit-test the wire framing (encode/decode) and the workspace/output JSON
mapping (esp. the `num` rule) as pure functions.

## Phase 2 — deep integration

- **GET_TREE** → map the tree to i3's node schema (`{id, name, type, layout, rect, window,
  window_properties, nodes, floating_nodes, focus, focused}`). **Gotcha:** X11-isms — map
  `window_properties.class` → app bundle-id, `.instance` → app name, i3 `window` id → CGWindowID;
  `layout` → `splith/splitv/tabbed/stacked` from our tiles/accordion/master. Tools doing X11-specific
  matching will approximate.
- **RUN_COMMAND full grammar** — the i3 command language *including `[criteria]` selectors*
  (`[class="Firefox" title="^Foo"] focus`). Real parser work; overlaps with i3-config command compat.
- `GET_BINDING_MODES`, `GET_CONFIG`, `GET_MARKS`, `SEND_TICK`, more `window`/`binding`/`mode` events.

## Guardrails

Separate socket (don't overload our protocol); no per-app branches; no AI co-author trailer; pure
wire/mapping logic extracted and unit-tested; honest scope in docs.

## Deferred

`GET_BAR_CONFIG` (only meaningful with i3bar — our bar is first-party, see the bar brief), marks,
sync, the X11-atom discovery path (impossible on macOS).
