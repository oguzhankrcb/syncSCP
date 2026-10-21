#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
"$TASK_ROOT/scripts/build-app.sh" --universal
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ditto -c -k --keepParent "dist/WinSCP for macOS.app" "dist/WinSCPMac-$TASK_VERSION-universal.zip"
python3 - "$TASK_VERSION" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import zipfile

root = Path.cwd()
version = sys.argv[1]
paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
source = root / 'dist' / ('WinSCPMac-' + version + '-source.zip')
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(set(paths) - {''}):
        path = root / name
        entry = 'WinSCPMac-' + version + '/' + name
        if path.is_symlink():
            info = zipfile.ZipInfo(entry)
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, os.readlink(path))
        elif path.is_file():
            archive.write(path, entry)
for name in ['WinSCPMac-' + version + '-universal.zip', source.name]:
    path = root / 'dist' / name
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'Archive integrity check failed'
    print(str(path) + ' — verified, ' + str(path.stat().st_size) + ' bytes')
PY
