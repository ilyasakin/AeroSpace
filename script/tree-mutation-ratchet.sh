#!/bin/zsh
# Ratchet on direct tree mutation.
#
# `bind(to:)` and `unbindFromParent()` are the two primitives that restructure the live tiling tree.
# Every caller is also responsible for invalidating the published structural spine, and that
# obligation is a convention the compiler cannot enforce — AppBundle is a single module, so
# `internal` protects nothing.
#
# The architecture plan considered sealing them behind a capability token. That is genuinely
# possible (a `~Copyable` struct with a `fileprivate` init cannot be forged — `unsafeBitCast` and
# `UnsafeRawPointer.load` both require `Copyable`, and the temporary-allocation route fails the
# borrow checker). It was rejected on cost: 54 call sites across 18 files, threaded through
# `TreeNode.init` — which means every test shape-builder moves too — to defend a bug class that a
# 684-case invariant sweep found to be entirely asymptomatic.
#
# This is the cheap 90%. It does not stop an existing file from mutating; it stops the surface from
# GROWING silently. A new file that reaches for the primitives fails CI and has to either route
# through the commit API or be added here deliberately, with review.
#
# If you are adding a file below, first check whether `commitTilingTransform` does what you want.

set -e
cd "$(dirname "$0")/.."

ALLOWED=(
  # Tree internals — the primitives and the structures that own them.
  Sources/AppBundle/tree/TreeNode.swift
  Sources/AppBundle/tree/Window.swift
  Sources/AppBundle/tree/MacWindow.swift
  Sources/AppBundle/tree/normalizeContainers.swift
  Sources/AppBundle/tree/frozen/closedWindowsCache.swift
  # The persistent-spine layer: this is the sanctioned mutation path.
  Sources/AppBundle/tree/persistent/LiveTreeBridge.swift
  Sources/AppBundle/tree/persistent/TilingStructureCommit.swift
  # Commands that restructure. Each is a candidate for a named tree operation later.
  Sources/AppBundle/command/impl/FlattenWorkspaceTreeCommand.swift
  Sources/AppBundle/command/impl/FocusCommand.swift
  Sources/AppBundle/command/impl/JoinWithCommand.swift
  Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift
  Sources/AppBundle/command/impl/MacosNativeMinimizeCommand.swift
  Sources/AppBundle/command/impl/MoveCommand.swift
  Sources/AppBundle/command/impl/MoveNodeToWorkspaceCommand.swift
  Sources/AppBundle/command/impl/SplitCommand.swift
  Sources/AppBundle/command/impl/ToggleGroupCommand.swift
  # Mouse drag/swap and the native-state normalizer.
  Sources/AppBundle/mouse/moveWithMouse.swift
  Sources/AppBundle/normalizeLayoutReason.swift
)

actual=$(grep -rlE '\bbind\(to:|unbindFromParent\(\)' Sources/AppBundle --include='*.swift' | sort)
allowed=$(printf '%s\n' "${ALLOWED[@]}" | sort)

new_files=$(comm -23 <(echo "$actual") <(echo "$allowed"))
if [[ -n "$new_files" ]]; then
    echo "ERROR: new file(s) mutate the tiling tree directly via bind/unbindFromParent:"
    echo "$new_files" | sed 's/^/  /'
    echo ""
    echo "Direct mutation must also invalidate the published structural spine, which nothing"
    echo "enforces. Prefer commitTilingTransform. If direct mutation is genuinely required, add the"
    echo "file to ALLOWED in script/tree-mutation-ratchet.sh so the decision is reviewed."
    exit 1
fi

# Also report shrinkage, so the allowlist doesn't rot into fiction once a file is migrated.
gone=$(comm -13 <(echo "$actual") <(echo "$allowed"))
if [[ -n "$gone" ]]; then
    echo "note: these files no longer mutate the tree directly — remove them from ALLOWED:"
    echo "$gone" | sed 's/^/  /'
fi

echo "tree-mutation ratchet: ok ($(echo "$actual" | wc -l | tr -d ' ') files, none new)"
