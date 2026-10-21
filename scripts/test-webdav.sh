#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PYTHON="$TASK_ROOT/.build/webdav-test-venv/bin/python"
if [ ! -x "$TEST_PYTHON" ]; then
    echo 'Run ./scripts/setup-webdav-tests.sh first (Python 3.11+).' >&2
    exit 2
fi
TASK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/syncscp-webdav-e2e.XXXXXX")"
WEBDAV_SERVER_PID=""
cleanup() {
    if [ -n "$WEBDAV_SERVER_PID" ]; then kill "$WEBDAV_SERVER_PID" 2>/dev/null || true; wait "$WEBDAV_SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$TASK_FIXTURE"
}
trap cleanup EXIT
"$TEST_PYTHON" "$TASK_ROOT/scripts/webdav-fixture.py" "$TASK_FIXTURE" > "$TASK_FIXTURE/server.log" 2>&1 &
WEBDAV_SERVER_PID=$!
for attempt in {1..100}; do
    if ! kill -0 "$WEBDAV_SERVER_PID" 2>/dev/null; then cat "$TASK_FIXTURE/server.log" >&2; exit 1; fi
    if [ -f "$TASK_FIXTURE/ready.json" ]; then break; fi
    sleep 0.1
done
if [ ! -f "$TASK_FIXTURE/ready.json" ]; then cat "$TASK_FIXTURE/server.log" >&2; exit 1; fi
export SYNCSCP_TEST_WEBDAV_FIXTURE="$TASK_FIXTURE"
if [ "${1:-}" = "--serve" ]; then
    cat "$TASK_FIXTURE/ready.json"
    printf '\nTest account: syncscp / test-only-password\nWebDAV path: /dav\nCA file: %s/ca.pem\nStop with Ctrl-C to remove this fixture.\n' "$TASK_FIXTURE"
    wait "$WEBDAV_SERVER_PID"
elif [ "${1:-}" = "--with-s3" ]; then
    shift
    "$TASK_ROOT/scripts/test-s3.sh" "$@"
else
    "$TASK_ROOT/scripts/swift.sh" test "$@"
fi
