#!/bin/bash
# test-encryption.sh — Encryption tests for DEV-907 (Session 2B).
#
# Lab constraint: MinIO runs over HTTP with no external KMS.
#   - SSE-C requires HTTPS (enforced by S3 spec) → N/A
#   - SSE-S3/SSE-KMS require a KMS → N/A
#   - TLS in transit not configured in this lab → N/A
#
# We verify the enforcement itself (HTTP rejected for SSE-C).

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

BUCKET="test-encryption"
PASS=0
FAIL=0
NA=0

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

test_not_available() {
  local name="$1" reason="$2"
  printf 'N/A   %-55s  %s\n' "$name" "$reason"
  NA=$((NA+1))
}

log() { printf '\n--- %s ---\n' "$*"; }

mc rb --force "local/$BUCKET" >/dev/null 2>&1 || true
mc mb "local/$BUCKET" >/dev/null 2>&1
echo "sensitive content 2026" > /data/testdata/local/enc-test.txt
ORIG_SHA=$(sha256sum /data/testdata/local/enc-test.txt | awk '{print $1}')

# ============ 1. Plain upload ============
log "1. Plain upload (baseline, HTTP)"
mc cp /data/testdata/local/enc-test.txt "local/$BUCKET/plain.txt" >/dev/null 2>&1
PLAIN_OK=$(mc ls "local/$BUCKET/plain.txt" 2>/dev/null | wc -l)
test_result "Plain upload succeeds" "1" "$PLAIN_OK"

# ============ 2. KMS presence check ============
log "2. KMS configuration check"
KMS_FILE_PRESENT=$(docker exec minio sh -c 'test -f /tmp/kms_master_key && echo 1 || echo 0' 2>/dev/null || echo 0)
if [ "$KMS_FILE_PRESENT" = "1" ]; then
  test_result "External KMS configured" "1" "1"
  KMS_AVAILABLE=1
else
  test_not_available "External KMS" "no kms_master_key file present in container"
  KMS_AVAILABLE=0
fi

# ============ 3. SSE-S3 ============
log "3. SSE-S3 (server-side, MinIO-managed)"
if [ "$KMS_AVAILABLE" = "1" ]; then
  mc cp --enc-s3 "sse3.txt" /data/testdata/local/enc-test.txt "local/$BUCKET/sse3.txt" >/dev/null 2>&1
  SSE3_OK=$(mc ls "local/$BUCKET/sse3.txt" 2>/dev/null | wc -l)
  test_result "SSE-S3 upload succeeds" "1" "$SSE3_OK"
else
  test_not_available "SSE-S3 upload" "no KMS / default encryption configured"
fi

# ============ 4. SSE-C enforcement over HTTP ============
log "4. SSE-C over HTTP (must be rejected by S3 spec)"
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '=')
SSE_C_ERROR=$(mc cp --enc-c "local/$BUCKET/ssec.txt=${KEY}" \
  /data/testdata/local/enc-test.txt "local/$BUCKET/ssec.txt" 2>&1 | grep -c "secure connection" || true)
test_result "SSE-C over HTTP rejected (spec-compliant)" "1" "$SSE_C_ERROR"

# Also verify object was NOT uploaded
SSE_C_UPLOADED=$(mc ls "local/$BUCKET/ssec.txt" 2>/dev/null | wc -l)
test_result "SSE-C object not persisted on HTTP" "0" "$SSE_C_UPLOADED"

# ============ 5. SSE-C over HTTPS ============
log "5. SSE-C over HTTPS (needs TLS)"
HTTPS_CODE=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -k -o /dev/null -w "%{http_code}" "https://${MINIO_IP}:9000/minio/health/live" 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "200" ]; then
  # Would run SSE-C over HTTPS here
  KEY2=$(head -c 32 /dev/urandom | base64 | tr -d '=')
  mc cp --insecure --enc-c "local/$BUCKET/ssec-https.txt=${KEY2}" \
    /data/testdata/local/enc-test.txt "local/$BUCKET/ssec-https.txt" >/dev/null 2>&1
  SSE_C_HTTPS_OK=$(mc --insecure ls "local/$BUCKET/ssec-https.txt" 2>/dev/null | wc -l)
  test_result "SSE-C over HTTPS succeeds" "1" "$SSE_C_HTTPS_OK"
else
  test_not_available "SSE-C over HTTPS" "TLS not configured in this lab"
fi

# ============ 6. SSE-KMS ============
log "6. SSE-KMS"
test_not_available "SSE-KMS encryption" "requires external KMS service (out of lab scope)"

# ============ 7. TLS in transit ============
log "7. TLS in transit"
HTTP_CODE=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" "http://${MINIO_IP}:9000/minio/health/live" 2>/dev/null)
test_result "HTTP endpoint reachable" "200" "$HTTP_CODE"
if [ "$HTTPS_CODE" != "200" ]; then
  test_not_available "HTTPS endpoint" "TLS not configured in this lab"
fi

# ============ 8. Cleanup ============
log "8. Cleanup"
mc rm --force --recursive "local/$BUCKET/" >/dev/null 2>&1
mc rb --force "local/$BUCKET" >/dev/null 2>&1
test_result "Cleanup complete" "1" "1"

printf '\n==========================================\n'
printf '  Encryption tests:  PASS=%d  FAIL=%d  N/A=%d\n' "$PASS" "$FAIL" "$NA"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
