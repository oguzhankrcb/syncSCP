#!/bin/bash
# Real S3 against disposable, localhost-only MinIO containers (HTTP and HTTPS).
# Uses generated test-only credentials and a throwaway CA; nothing is installed on the host.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Community MinIO images are no longer published; this pinned Bitnami legacy build is test-only.
MINIO_IMAGE="bitnamilegacy/minio:2025.7.23@sha256:8935e75fa5d11295c17171e4aa49efe390a1193cd7f12e4d21b92af9ffef09d7"
if [ "${WINSCP_SKIP_S3:-}" = "1" ] && [ "${1:-}" != "--serve" ]; then
    # Explicit opt-out for hosts without Docker (e.g. hosted macOS CI); S3 integration tests report as skipped.
    echo 'WINSCP_SKIP_S3=1: S3 integration tests will be skipped.' >&2
    exec "$TASK_ROOT/scripts/swift.sh" test "$@"
fi
if ! docker info >/dev/null 2>&1; then
    echo 'S3 tests need a running Docker daemon for the disposable MinIO fixture (or set WINSCP_SKIP_S3=1 to skip them explicitly).' >&2
    exit 2
fi
TASK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/winscp-s3-e2e.XXXXXX")"
SUFFIX="$(basename "$TASK_FIXTURE" | tr -dc 'a-zA-Z0-9' | tr 'A-Z' 'a-z')"
HTTP_CONTAINER="winscp-s3-http-$SUFFIX"
TLS_CONTAINER="winscp-s3-tls-$SUFFIX"
cleanup() {
    docker rm -f "$HTTP_CONTAINER" "$TLS_CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$TASK_FIXTURE"
}
trap cleanup EXIT

mkdir -p "$TASK_FIXTURE/certs" "$TASK_FIXTURE/local"
cat > "$TASK_FIXTURE/server.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[ext]
basicConstraints = critical,CA:FALSE
subjectAltName = DNS:localhost
extendedKeyUsage = serverAuth
EOF
openssl req -quiet -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=WinSCP S3 disposable CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$TASK_FIXTURE/ca.key" -out "$TASK_FIXTURE/ca.pem" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -config "$TASK_FIXTURE/server.cnf" \
    -keyout "$TASK_FIXTURE/certs/private.key" -out "$TASK_FIXTURE/server.csr" 2>/dev/null
openssl x509 -req -in "$TASK_FIXTURE/server.csr" -CA "$TASK_FIXTURE/ca.pem" -CAkey "$TASK_FIXTURE/ca.key" -CAcreateserial \
    -days 1 -extfile "$TASK_FIXTURE/server.cnf" -extensions ext -out "$TASK_FIXTURE/certs/public.crt" 2>/dev/null
# The container runs as an unprivileged user; the key is disposable and removed on exit.
chmod 755 "$TASK_FIXTURE/certs"; chmod 644 "$TASK_FIXTURE/certs/private.key" "$TASK_FIXTURE/certs/public.crt"
printf 'Native S3 upload.\n' > "$TASK_FIXTURE/local/upload.txt"

ROOT_USER="winscp-root"
ROOT_PASSWORD="test-only-root-$(openssl rand -hex 12)"
start() { # name, extra minio arguments…
    local name="$1"; shift
    docker run -d --rm --name "$name" -p 127.0.0.1::9000 \
        -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASSWORD" -e MINIO_BROWSER=off -e MINIO_SITE_REGION=us-east-1 \
        "$@" >/dev/null
}
start "$HTTP_CONTAINER" --entrypoint minio "$MINIO_IMAGE" server /tmp/minio-data --address :9000 --quiet
start "$TLS_CONTAINER" -v "$TASK_FIXTURE/certs:/certs:ro" --entrypoint minio "$MINIO_IMAGE" server /tmp/minio-data --address :9000 --certs-dir /certs --quiet
HTTP_PORT="$(docker port "$HTTP_CONTAINER" 9000/tcp | head -1 | sed 's/.*://')"
TLS_PORT="$(docker port "$TLS_CONTAINER" 9000/tcp | head -1 | sed 's/.*://')"
for attempt in {1..150}; do
    if curl -fs "http://127.0.0.1:$HTTP_PORT/minio/health/live" >/dev/null && \
       curl -fs --cacert "$TASK_FIXTURE/ca.pem" "https://localhost:$TLS_PORT/minio/health/live" >/dev/null; then break; fi
    if [ "$attempt" = 150 ]; then docker logs "$HTTP_CONTAINER" >&2 || true; docker logs "$TLS_CONTAINER" >&2 || true; exit 1; fi
    sleep 0.2
done

configure() { # container, scheme
    docker exec "$1" sh -c '
        set -e
        mc() { /opt/bitnami/minio-client/bin/mc --config-dir /tmp/mc --insecure "$@"; }
        mc alias set local "$0://localhost:9000" "$1" "$2" >/dev/null
        mc mb local/winscp-test local/winscp-empty >/dev/null
        mc admin user add local winscp-tester test-only-secret-key >/dev/null
        mc admin policy attach local readwrite --user winscp-tester >/dev/null
        # The built-in readonly policy cannot list buckets; browsing needs ListBucket too.
        printf %s "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\",\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::winscp-test\",\"arn:aws:s3:::winscp-test/*\"]}]}" > /tmp/browse.json
        mc admin policy create local winscp-browse /tmp/browse.json >/dev/null
        mc admin user add local winscp-reader test-only-reader-key >/dev/null
        mc admin policy attach local winscp-browse --user winscp-reader >/dev/null
        printf "S3 fixture · İstanbul · 日本語\n" > /tmp/welcome.txt
        mc cp /tmp/welcome.txt local/winscp-test/welcome.txt >/dev/null
    ' "$2" "$ROOT_USER" "$ROOT_PASSWORD"
}
configure "$HTTP_CONTAINER" http
configure "$TLS_CONTAINER" https
printf '{"http_port": %s, "https_port": %s}\n' "$HTTP_PORT" "$TLS_PORT" > "$TASK_FIXTURE/ready.json"
export WINSCP_TEST_S3_FIXTURE="$TASK_FIXTURE"
if [ "${1:-}" = "--serve" ]; then
    cat "$TASK_FIXTURE/ready.json"
    printf '\nHost: localhost (path-style), region us-east-1, bucket path /winscp-test\nAccess key: winscp-tester / test-only-secret-key (read-only: winscp-reader / test-only-reader-key)\nCA file: %s/ca.pem\nStop with Ctrl-C to remove both containers and this fixture.\n' "$TASK_FIXTURE"
    while docker inspect "$TLS_CONTAINER" >/dev/null 2>&1; do sleep 1; done
else
    "$TASK_ROOT/scripts/swift.sh" test "$@"
fi
