#!/usr/bin/env python3
"""Prepare an owned generated consumer; production example dependencies remain unchanged."""
import json
from pathlib import Path
import re
import shutil
import sys


def prepare(sdk: Path, app: Path) -> None:
    marker = app / '.corlex-integration-owned'
    if app.name != 'app' or not app.parent.name.startswith('corlex-flutter-integration.') or marker.is_symlink() or marker.read_text() != 'Corlex generated integration consumer\n':
        raise ValueError('Only an owned temporary integration consumer may be prepared')
    fixture = sdk / 'test/integration'
    (app / 'pubspec.yaml').write_text(f"""name: corlex_integration_probe
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.4.0
dependencies:
  flutter:
    sdk: flutter
  corlex_flutter:
    path: {json.dumps(str(sdk))}
dev_dependencies:
  integration_test:
    sdk: flutter
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
flutter:
  uses-material-design: true
""")
    lock = (fixture / 'pubspec.lock').read_text()
    assert lock.count('"__SDK_PATH__"') == 1
    (app / 'pubspec.lock').write_text(lock.replace('"__SDK_PATH__"', json.dumps(str(sdk))))
    tests = app / 'integration_test'
    tests.mkdir()
    shutil.copyfile(fixture / 'protected_state_test.dart.template', tests / 'protected_state_test.dart')
    project = app / 'ios/Runner.xcodeproj/project.pbxproj'
    project.write_text(re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;', 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;', project.read_text()))
    podfile = app / 'ios/Podfile'
    if not podfile.exists():
        shutil.copyfile(sdk / 'example/ios/Podfile', podfile)
    podfile.write_text(re.sub(r"(?m)^#?\s*platform :ios,.*$", "platform :ios, '15.0'", podfile.read_text()))


if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve(strict=True), Path(sys.argv[2]).resolve(strict=True))
