#!/bin/bash
# Real SFTP and legacy SCP against disposable localhost SSH daemons.
# Uses only generated test keys; does not change ~/.ssh or system SSH settings.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/winscp-ssh-e2e.XXXXXX")"
SSH_DAEMON_PID=""
SCP_DAEMON_PID=""
cleanup() {
    if [ -n "$SSH_DAEMON_PID" ]; then kill "$SSH_DAEMON_PID" 2>/dev/null || true; wait "$SSH_DAEMON_PID" 2>/dev/null || true; fi
    if [ -n "$SCP_DAEMON_PID" ]; then kill "$SCP_DAEMON_PID" 2>/dev/null || true; wait "$SCP_DAEMON_PID" 2>/dev/null || true; fi
    rm -rf "$TASK_FIXTURE"
}
trap cleanup EXIT
TASK_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
ssh-keygen -q -t ed25519 -N '' -f "$TASK_FIXTURE/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$TASK_FIXTURE/client_key"
cp "$TASK_FIXTURE/client_key.pub" "$TASK_FIXTURE/authorized_keys"
mkdir "$TASK_FIXTURE/remote"
awk -v host="[127.0.0.1]:$TASK_PORT" '{ print host, $1, $2 }' "$TASK_FIXTURE/host_key.pub" > "$TASK_FIXTURE/known hosts"
cat > "$TASK_FIXTURE/sshd_config" <<EOF
Port $TASK_PORT
ListenAddress 127.0.0.1
HostKey "$TASK_FIXTURE/host_key"
PidFile "$TASK_FIXTURE/sshd.pid"
AuthorizedKeysFile "$TASK_FIXTURE/authorized_keys"
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
UseDNS no
AllowUsers $(id -un)
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
EOF
/usr/sbin/sshd -D -e -f "$TASK_FIXTURE/sshd_config" > "$TASK_FIXTURE/sshd.log" 2>&1 &
SSH_DAEMON_PID=$!
for attempt in {1..30}; do
    if ! kill -0 "$SSH_DAEMON_PID" 2>/dev/null; then cat "$TASK_FIXTURE/sshd.log" >&2; exit 1; fi
    if ssh-keyscan -T 1 -p "$TASK_PORT" -t ed25519 127.0.0.1 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
# A second daemon has no SFTP subsystem: SCP tests cannot silently pass via SFTP.
TASK_SCP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
awk -v port="$TASK_SCP_PORT" -v pid="$TASK_FIXTURE/sshd_scp.pid" '
    /^Port / { print "Port " port; next }
    /^Subsystem / { next }
    /^PidFile / { print "PidFile \"" pid "\""; next }
    { print }
' "$TASK_FIXTURE/sshd_config" > "$TASK_FIXTURE/sshd_scp_config"
awk -v host="[127.0.0.1]:$TASK_SCP_PORT" '{ print host, $1, $2 }' "$TASK_FIXTURE/host_key.pub" >> "$TASK_FIXTURE/known hosts"
/usr/sbin/sshd -D -e -f "$TASK_FIXTURE/sshd_scp_config" > "$TASK_FIXTURE/sshd_scp.log" 2>&1 &
SCP_DAEMON_PID=$!
for attempt in {1..30}; do
    if ! kill -0 "$SCP_DAEMON_PID" 2>/dev/null; then cat "$TASK_FIXTURE/sshd_scp.log" >&2; exit 1; fi
    if ssh-keyscan -T 1 -p "$TASK_SCP_PORT" -t ed25519 127.0.0.1 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
export WINSCP_TEST_SCP_PORT="$TASK_SCP_PORT"
export WINSCP_TEST_SSH_FIXTURE="$TASK_FIXTURE"
export WINSCP_TEST_SSH_PORT="$TASK_PORT"
if [ "${1:-}" = "--serve" ]; then
    cp "$TASK_ROOT/README.tr.md" "$TASK_FIXTURE/remote/README.txt"
    printf 'Fixture directory: %s\nSFTP port: %s\nSCP-only port: %s\nStop with Ctrl-C; all fixture files and keys are removed.\n' "$TASK_FIXTURE" "$TASK_PORT" "$TASK_SCP_PORT"
    ssh-keygen -lf "$TASK_FIXTURE/host_key.pub"
    wait "$SSH_DAEMON_PID"
    exit 0
fi
if [ "${1:-}" = "--all" ]; then
    shift
    "$TASK_ROOT/scripts/test-ftp.sh" --with-webdav "$@"
else
    "$TASK_ROOT/scripts/swift.sh" test "$@"
fi
