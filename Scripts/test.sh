#!/bin/bash
# Runs the unit tests (Tests/KlipKlikTests).
#
# This machine has only the Command Line Tools, which ship swift-testing but
# do not put it on the default search paths — so the framework and its
# interop library are pointed at by hand. With full Xcode installed, plain
# `swift test` works too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

if [ -d "$FW/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F"$FW" \
        -Xlinker -F"$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIB" \
        "$@"
fi

exec swift test "$@"
