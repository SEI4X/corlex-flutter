#!/bin/sh
# Build the real-client fixture only in an owned temporary consumer, never in the shipped example.
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: scripts/test-integration.sh <simulator-or-device-id>" >&2; exit 2; fi
device=$1
sdk=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
flutter=${FLUTTER_BIN:-flutter}
work=$(mktemp -d "${TMPDIR:-/tmp}/corlex-flutter-integration.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
"$flutter" create --no-pub --empty --platforms android,ios --org ru.corlex.testing --project-name corlex_integration_probe "$work/app"
printf "%s\n" "Corlex generated integration consumer" > "$work/app/.corlex-integration-owned"
python3 "$sdk/scripts/prepare-integration.py" "$sdk" "$work/app"
cd "$work/app"
"$flutter" pub get --enforce-lockfile
"$flutter" test integration_test/protected_state_test.dart -d "$device"
