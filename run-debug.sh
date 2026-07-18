#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

./build-debug.sh

# Prefer the .app bundle so TCC Accessibility stays on bobko.aerospace.debug.
# Bare .debug/AeroSpaceApp has no bundle id and breaks AX grants.
if [[ -d .debug/AeroSpaceDebug.app ]]; then
    open .debug/AeroSpaceDebug.app
else
    ./.debug/AeroSpaceApp "$@"
fi
