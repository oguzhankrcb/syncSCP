#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m venv "$TASK_ROOT/.build/webdav-test-venv"
"$TASK_ROOT/.build/webdav-test-venv/bin/python" -m pip install --cache-dir "$TASK_ROOT/.build/pip-cache" -r "$TASK_ROOT/scripts/webdav-test-requirements.txt"
