#!/usr/bin/env python3
"""Verify only reviewed files inside this standalone SDK, without reading a sibling checkout."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'ios/native-core-manifest.json').read_text())
expected = {'CorlexCrash.c', 'CorlexImages.c', 'CorlexStack.c', 'CorlexOutput.c', 'CorlexInternal.h', 'CorlexCrash.h'}
assert manifest['version'] == 1 and manifest['license'] == 'MIT'
assert {row['target'] for row in manifest['files']} == expected and len(manifest['files']) == len(expected)
for row in manifest['files']:
    path = root / 'ios/Classes/CorlexCrash' / row['target']
    assert not path.is_symlink()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest == row['sha256'] == row['sourceSha256'], f"Native C checksum mismatch: {row['target']}"
privacy = root / 'ios/Resources/PrivacyInfo.xcprivacy'
assert hashlib.sha256(privacy.read_bytes()).hexdigest() == manifest['privacySha256'], 'Privacy manifest checksum mismatch'
print('Reviewed standalone native C and platform privacy checksums passed')
