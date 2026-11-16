#!/bin/sh
# Runs the tests. With the Command Line Tools alone, SwiftPM does not find the macros of Swift Testing by itself, so
# their folder is passed along; with Xcode it is found without help.
set -e
cd "$(dirname "$0")/.."
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
