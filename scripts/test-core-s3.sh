#!/bin/bash
# test-core-s3.sh — Core S3 API surface tests against MinIO.

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"

MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio)
[ -z "$MINIO_IP" ] && { echo "ERROR: MinIO container not found" >&2; exit 1; }

MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

mc() {
  docker run --rm --network "$MC_NET" \
    -v /data/testdata:/data/testdata \
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

BUCKET="test-core-s3"
PASS=0
FAIL=0

test_result() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %-55s  %s\n' "$name" "$actual"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %-55s  expected=%s  got=%s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL+1))
  fi
}

log() { printf '\n--- %s ---\n' "$*"; }

mc rb --force "local/$BUCKET" >/dev/null 2>&1 || true

log "1. Bucket create"
mc mb "local/$BUCKET" >/dev/null 2>&1
EXIST=$(mc ls local/ | grep -c "$BUCKET/")
test_result "bucket created" "1" "$EXIST"

log "2. PUT object"
echo "hello-minio" > /data/testdata/local/core-test-1.txt
mc cp /data/testdata/local/core-test-1.txt "local/$BUCKET/obj-1.txt" >/dev/null 2>&1
PUT_OK=$(mc ls "local/$BUCKET/obj-1.txt" 2>/dev/null | wc -l)
test_result "PUT object" "1" "$PUT_OK"

log "3. HEAD object (stat)"
HEAD_SIZE_RAW=$(mc stat "local/$BUCKET/obj-1.txt" 2>/dev/null | awk -F: '/^Size/{print $2}' | tr -d ' ' | head -1)
HEAD_SIZE=$(echo "$HEAD_SIZE_RAW" | sed 's/B$//')
test_result "HEAD object (size=12)" "12" "$HEAD_SIZE"

log "4. GET object"
mc cp "local/$BUCKET/obj-1.txt" /data/testdata/local/core-test-1-downloaded.txt >/dev/null 2>&1
ORIG_SHA=$(sha256sum /data/testdata/local/core-test-1.txt | awk '{print $1}')
DL_SHA=$(sha256sum /data/testdata/local/core-test-1-downloaded.txt | awk '{print $1}')
test_result "GET object (sha256 match)" "$ORIG_SHA" "$DL_SHA"

log "5. Copy object (server-side)"
mc cp "local/$BUCKET/obj-1.txt" "local/$BUCKET/obj-1-copy.txt" >/dev/null 2>&1
COPY_OK=$(mc ls "local/$BUCKET/obj-1-copy.txt" 2>/dev/null | wc -l)
test_result "Copy object" "1" "$COPY_OK"

log "6. Range read (bytes 0-4)"
# mcli has no direct byte-range read; use full cat + head
RANGE=$(mc cat "local/$BUCKET/obj-1.txt" 2>/dev/null | head -c 5)
test_result "Range read 0-4" "hello" "$RANGE"

log "7. Multipart upload (7 MB)"
dd if=/dev/urandom of=/data/testdata/local/multipart-7mb.bin bs=1M count=7 2>/dev/null
mc cp /data/testdata/local/multipart-7mb.bin "local/$BUCKET/multipart.bin" >/dev/null 2>&1
# mcli prints "Size      : 7340032 B" (or "7.0MiB B" in newer versions)
# Extract the numeric portion before the unit
MP_SIZE_RAW=$(mc stat "local/$BUCKET/multipart.bin" 2>/dev/null | awk -F: '/^Size/{print $2}' | tr -d ' ' | head -1)
# If format is "7340032B" keep it; if "7.0MiB" convert to bytes
if echo "$MP_SIZE_RAW" | grep -qE '^[0-9]+B$'; then
  MP_SIZE=$(echo "$MP_SIZE_RAW" | sed 's/B//')
elif echo "$MP_SIZE_RAW" | grep -qE 'MiB$'; then
  MP_SIZE=$(echo "$MP_SIZE_RAW" | sed 's/MiB//' | awk '{printf "%d", $1 * 1048576}')
else
  MP_SIZE="$MP_SIZE_RAW"
fi
test_result "Multipart upload size" "7340032" "$MP_SIZE"

log "8. Presigned URL generation"
PRESIGNED=$(mc share download --expire 1h "local/$BUCKET/obj-1.txt" 2>&1 | awk '/^Share:/{print $2}' | head -1)
if [ -n "$PRESIGNED" ] && echo "$PRESIGNED" | grep -q "X-Amz-Signature"; then
  test_result "Presigned URL generated" "1" "1"
else
  test_result "Presigned URL generated" "1" "0"
fi

log "9. Presigned URL fetch"
# The presigned URL signs the host header, so we must fetch using the
# exact same URL. Our curl container is on the same docker network, so it
# can reach ${MINIO_IP} directly.
HTTP_CODE=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" "$PRESIGNED" 2>/dev/null)
test_result "Presigned URL fetch (HTTP)" "200" "$HTTP_CODE"

log "10. List (flat)"
LIST_COUNT=$(mc ls "local/$BUCKET/" 2>/dev/null | grep -c "obj-1.txt\|multipart.bin")
test_result "List objects" "2" "$LIST_COUNT"

log "11. List recursive"
RECURSIVE_COUNT=$(mc ls --recursive "local/$BUCKET/" 2>/dev/null | wc -l)
test_result "List recursive count" "3" "$RECURSIVE_COUNT"

log "12. Batch delete"
mc rm --force "local/$BUCKET/obj-1-copy.txt" "local/$BUCKET/multipart.bin" >/dev/null 2>&1
REMAIN=$(mc ls "local/$BUCKET/" 2>/dev/null | wc -l)
test_result "Batch delete (remaining)" "1" "$REMAIN"

log "13. Delete single object"
mc rm --force "local/$BUCKET/obj-1.txt" >/dev/null 2>&1
EMPTY=$(mc ls "local/$BUCKET/" 2>/dev/null | wc -l)
test_result "Delete single object (empty)" "0" "$EMPTY"

log "14. Delete bucket"
mc rb "local/$BUCKET" >/dev/null 2>&1
GONE=$(mc ls local/ | grep -c "$BUCKET/" || true)
test_result "Bucket deleted" "0" "$GONE"

printf '\n==========================================\n'
printf '  Core S3 tests:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
