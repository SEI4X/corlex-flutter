#!/bin/bash
# The iOS plugin compiles the crash handler of the iOS SDK (packages/sdk-ios) from copies in its own
# folder: a pub package cannot reach outside its directory. This checks the copies are byte-identical,
# so a fix in one place cannot be forgotten in the other. To update: copy the files over (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/verify-native.py
python3 scripts/verify-state.py
python3 scripts/check-privacy.py --platform flutter --manifest ios/Resources/PrivacyInfo.xcprivacy
# A standalone public SDK never guesses or reads a sibling checkout.
# Private CI supplies the canonical own source directory explicitly.
if [ -z "${CORLEX_IOS_SOURCES:-}" ]; then exit 0; fi
ios=$CORLEX_IOS_SOURCES
copy=ios/Classes/CorlexCrash
status=0
check() {
  if ! cmp "$1" "$2"; then
    echo "differs: $2 (copy of $1)" >&2
    status=1
  fi
}

for file in CorlexCrash.c CorlexImages.c CorlexStack.c CorlexOutput.c CorlexInternal.h; do
  check "$ios/CCorlexCrash/$file" "$copy/$file"
done
check "$ios/CCorlexCrash/include/CorlexCrash.h" "$copy/CorlexCrash.h"
python3 scripts/check-privacy.py --platform flutter --manifest ios/Resources/PrivacyInfo.xcprivacy --canonical "$ios/Corlex/Resources/PrivacyInfo.xcprivacy"
exit $status
