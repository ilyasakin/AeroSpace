#!/bin/zsh
cd "$(dirname "$0")"
source ./script/setup.sh

./build-debug.sh > /dev/null || ./build-debug.sh
./.debug/aerospace "$@"
