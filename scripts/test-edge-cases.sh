#!/bin/bash
# test-edge-cases.sh — Edge-case compatibility tests (DEV-912).
# Lighter version: serialized bulk, smaller scale.

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

mc() {
  docker run --rm --network "$MC_NET" \
    -v "$MC_CFG_VOL":/root/.mc \
    -v /data/testdata:/data/testdata \
    "$MC_IMAGE" "$@"
}

curl_run() {
  docker run --rm --network "$MC_NET" curlimages/curl:latest "$@"
}

BUCKET="edge-test"

run_against() {
  local TARGET="$1"
  local ENDPOINT="http://${TARGET}:9000"
  local OUT="/tmp/edge-${TARGET}.txt"
  : > "$OUT"

  {
    echo "=== Edge-case tests against ${TARGET} ==="
    echo "Endpoint: ${ENDPOINT}"
    echo "Date: $(date -Iseconds)"
    echo ""
  } >> "$OUT"

  mc rb --force --dangerous "${TARGET}/${BUCKET}" >/dev/null 2>&1 || true
  mc mb "${TARGET}/${BUCKET}" >/dev/null 2>&1

  echo "=== 1. Basic PUT/DELETE works ===" | tee -a "$OUT"
  echo "test" > /data/testdata/local/edge-1.txt
  mc cp /data/testdata/local/edge-1.txt "${TARGET}/${BUCKET}/obj1.txt" >/dev/null 2>&1
  EXISTS=$(mc ls "${TARGET}/${BUCKET}/obj1.txt" 2>/dev/null | wc -l)
  echo "  After PUT, object exists: $EXISTS" | tee -a "$OUT"

  echo "=== 2. Batch delete 3 keys in one command ===" | tee -a "$OUT"
  for i in 1 2 3; do
    echo "batch-$i" > /data/testdata/local/batch-$i.txt
    mc cp /data/testdata/local/batch-$i.txt "${TARGET}/${BUCKET}/batch-$i.txt" >/dev/null 2>&1
  done
  BEFORE=$(mc ls "${TARGET}/${BUCKET}/" 2>/dev/null | wc -l)
  mc rm --force "${TARGET}/${BUCKET}/batch-1.txt" "${TARGET}/${BUCKET}/batch-2.txt" "${TARGET}/${BUCKET}/batch-3.txt" >/dev/null 2>&1
  AFTER=$(mc ls "${TARGET}/${BUCKET}/" 2>/dev/null | wc -l)
  echo "  Objects before: $BEFORE, after: $AFTER" | tee -a "$OUT"

  echo "=== 3. Bulk delete 50 objects ===" | tee -a "$OUT"
  echo "x" > /data/testdata/local/x.txt
  for i in $(seq 1 50); do
    mc cp /data/testdata/local/x.txt "${TARGET}/${BUCKET}/bulk-$(printf %03d $i).txt" >/dev/null 2>&1
  done
  BULK_BEFORE=$(mc ls "${TARGET}/${BUCKET}/" 2>/dev/null | grep -c "bulk-" || true)
  echo "  Bulk objects created: $BULK_BEFORE" | tee -a "$OUT"
  mc rm --force --recursive "${TARGET}/${BUCKET}/bulk-" >/dev/null 2>&1
  BULK_AFTER=$(mc ls "${TARGET}/${BUCKET}/" 2>/dev/null | grep -c "bulk-" || true)
  echo "  After recursive delete: $BULK_AFTER bulk objects remain" | tee -a "$OUT"

  echo "=== 4. Error response for missing bucket (unauthenticated) ===" | tee -a "$OUT"
  ERROR_OUT=$(curl_run -s "${ENDPOINT}/nonexistent-bucket-xyz/" 2>/dev/null | head -c 400)
  echo "  Response body: ${ERROR_OUT}" | tee -a "$OUT"

  echo "=== 5. Error response for missing object (unauthenticated) ===" | tee -a "$OUT"
  ERROR_OBJ=$(curl_run -s "${ENDPOINT}/${BUCKET}/nonexistent.txt" 2>/dev/null | head -c 400)
  echo "  Response body: ${ERROR_OBJ}" | tee -a "$OUT"

  echo "=== 6. HTTP status codes (unauthenticated probes) ===" | tee -a "$OUT"
  for PROBE in "" "/${BUCKET}/" "/nonexistent-bucket/" "/${BUCKET}/nonexistent.txt"; do
    CODE=$(curl_run -s -o /dev/null -w "%{http_code}" "${ENDPOINT}${PROBE}" 2>/dev/null)
    echo "  GET ${ENDPOINT}${PROBE} -> HTTP ${CODE}" | tee -a "$OUT"
  done

  echo "=== 7. ACL API probe ===" | tee -a "$OUT"
  CODE_ACL=$(curl_run -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/${BUCKET}/?acl" 2>/dev/null)
  echo "  GET ?acl -> HTTP ${CODE_ACL}" | tee -a "$OUT"

  echo "=== 8. Conditional PUT (If-None-Match: *) probe ===" | tee -a "$OUT"
  CODE_CNM=$(curl_run -s -o /dev/null -w "%{http_code}" \
    -X PUT -H "If-None-Match: *" --data-binary "new" \
    "${ENDPOINT}/${BUCKET}/cond.txt" 2>/dev/null)
  echo "  PUT with If-None-Match:* -> HTTP ${CODE_CNM}" | tee -a "$OUT"

  echo "=== 9. Prometheus metrics endpoint ===" | tee -a "$OUT"
  TOKEN=$(mc admin prometheus generate "$TARGET" 2>&1 | awk '/^token:/{print $2}' | head -1)
  [ -z "$TOKEN" ] && TOKEN=$(mc admin prometheus generate "$TARGET" 2>&1 | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1)
  if [ -n "$TOKEN" ]; then
    METRIC_COUNT=$(curl_run -s -H "Authorization: Bearer ${TOKEN}" \
      "${ENDPOINT}/minio/v2/metrics/cluster" 2>/dev/null | grep -c "^minio_" || echo 0)
    echo "  Metrics at /minio/v2/metrics/cluster: $METRIC_COUNT lines" | tee -a "$OUT"
  else
    echo "  Metrics: no token generated" | tee -a "$OUT"
  fi

  # Cleanup
  mc rb --force --dangerous "${TARGET}/${BUCKET}" >/dev/null 2>&1 || true

  echo "" | tee -a "$OUT"
  echo "=== End ===" | tee -a "$OUT"
}

echo "===== Running against MINIO ====="
run_against "minio"
cp /tmp/edge-minio.txt docs/08-compatibility-diff/evidence/edge-cases-minio.txt

echo ""
echo "===== Running against SILO ====="
run_against "silo"
cp /tmp/edge-silo.txt docs/08-compatibility-diff/evidence/edge-cases-silo.txt

echo ""
echo "===== DIFF MinIO vs Silo ====="
diff docs/08-compatibility-diff/evidence/edge-cases-minio.txt \
     docs/08-compatibility-diff/evidence/edge-cases-silo.txt \
  > docs/08-compatibility-diff/evidence/edge-cases-diff.txt || true

if [ -s docs/08-compatibility-diff/evidence/edge-cases-diff.txt ]; then
  echo "Differences found:"
  cat docs/08-compatibility-diff/evidence/edge-cases-diff.txt
else
  echo "✅ No differences between MinIO and Silo behavior"
fi

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
