#!/bin/sh
# Foundation-only physical state probe; does not require Flutter.framework or a host application.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc ios/Classes/CorlexFlutterPrivacyJson.swift ios/Classes/CorlexFlutterProcessPrivacy.swift ios/Classes/CorlexFlutterStateCodec.swift ios/Classes/CorlexFlutterStateStore.swift test/native_state/main.swift -o "$work/state-probe"
"$work/state-probe"
swiftc ios/Classes/CorlexFlutterPrivacyJson.swift ios/Classes/CorlexFlutterProcessPrivacy.swift ios/Classes/CorlexFlutterStateCodec.swift ios/Classes/CorlexFlutterStateStore.swift test/native_process/main.swift -o "$work/process-probe"
"$work/process-probe"
