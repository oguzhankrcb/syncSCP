#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$TASK_ROOT/scripts/setup-ftp-tests.sh"
"$TASK_ROOT/scripts/setup-webdav-tests.sh"
