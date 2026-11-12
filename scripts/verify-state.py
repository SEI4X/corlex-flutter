#!/usr/bin/env python3
"""Verify the allowlisted own native state helpers in a standalone Flutter SDK checkout."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'state-protocol-manifest.json').read_text())
expected = {'android/src/main/kotlin/ru/corlex/flutter/CorlexFlutterPrivacyJson.kt', 'android/src/main/kotlin/ru/corlex/flutter/CorlexFlutterProcessPrivacy.kt', 'ios/Classes/CorlexFlutterPrivacyJson.swift', 'ios/Classes/CorlexFlutterProcessPrivacy.swift', 'ios/Classes/CorlexFlutterStateCodec.swift', 'ios/Classes/CorlexFlutterStateStore.swift',
'android/src/main/kotlin/ru/corlex/flutter/CorlexFlutterStateCodec.kt', 'android/src/main/kotlin/ru/corlex/flutter/CorlexFlutterStateStore.kt'}
assert manifest['version'] == 1 and manifest['license'] == 'MIT' and manifest['sourceSdk'] == 'corlex-react-native'
assert len(manifest['files']) == len(expected) and {row['target'] for row in manifest['files']} == expected
for row in manifest['files']:
    path = root / row['target']
    assert not path.is_symlink()
    assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], f"State helper checksum mismatch: {row['target']}"
print('Flutter standalone protected-state checksums passed')
