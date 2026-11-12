#!/bin/sh
# Physical Foundation/C reporter; metadata is the only injected platform boundary.
set -eu
cd "$(dirname "$0")/.."
python3 scripts/verify-state.py
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-flutter-crash.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
core=ios/Classes/CorlexCrash
for source in "$core"/*.c; do
    clang -O2 -fsanitize=address,undefined -I "$core" -c "$source" -o "$work/$(basename "$source" .c).o"
done
fixture=test/native_crash
if [ "${1:-}" = channel ]; then fixture=test/native_channel; fi
set --
for source in ios/Classes/CorlexFlutter*.swift; do
    case "$source" in *Plugin.swift) continue ;; esac
    set -- "$@" "$source"
done
swiftc -sanitize=address -import-objc-header "$core/CorlexCrash.h" "$@" \
    ios/Classes/ProtectedStateChannel.swift ios/Classes/CorlexCrashCapture.swift \
    ios/Classes/CorlexNativeCrash*.swift test/native_crash/DeviceFacts.swift \
    "$fixture/main.swift" "$work"/*.o -o "$work/crash-probe"
if [ "$fixture" = test/native_channel ]; then "$work/crash-probe"; exit 0; fi
for mode in default details boundary oversize blocked stale-disable; do
    "$work/crash-probe" "$mode" "$work/state-$mode"
done
