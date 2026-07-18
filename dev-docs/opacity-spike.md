# M4 opacity spike — SkyLight alpha on foreign windows

**Date:** 2026-07-18  
**Conclusion:** **Not shipping** `active_opacity` / `inactive_opacity`.

## What we checked

AeroSpace already uses private SkyLight for **read** paths (window bounds, on-screen stack)
under the existing SIP-safe profile. The M4 brief requires dimming **other apps'** windows via
something like `SLSSetWindowAlpha` (or equivalent) **without** elevated permissions or SIP
changes.

## Finding

1. There is no public AppKit/Accessibility API to set opacity of another process's windows.
2. Private SkyLight symbols for per-window alpha, when present on a given macOS build, are not
   a supported contract for mutating **foreign** windows under SIP. Writing alpha on windows we
   do not own is either a no-op, permission-gated, or unstable across OS versions.
3. Shipping a flaky half-working dim would violate project guardrails (SIP-free, no per-app
   branches, no compositor pretence).

## Decision

- **Drop** runtime opacity config and application for M4.
- Keep border gradient/glow and group tab bar as the self-rendered Hyprland look.
- Document Hyprland `opacity` window rules as unsupported (importer continues to skip with a
  clear diagnostic).
- Revisit only if a SIP-free, cross-app alpha path becomes available and testable.

## Related

- Importer: `windowrulev2 = opacity …` → skipped diagnostic (existing).
- Borders: solid | gradient | glow (shipped).
- Groups: accordion + tab strip (shipped).
