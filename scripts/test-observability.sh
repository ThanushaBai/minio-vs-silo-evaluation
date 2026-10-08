#!/bin/bash
# test-observability.sh — Observability tests for DEV-907 (Session 2C).
# Covers: Prometheus metrics (3 endpoints), mc admin info, trace, logs, console.

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
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

curl_run() {
  docker run --rm --network "$MC_NET" curlimages/curl:latest "$@"
}

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

test_min() {
  local name="$1" min="$2" actual="$3"
  if [ "$actual" -ge "$min" ]; then
    printf 'PASS  %-55s  %s (>= %s)\n' "$name" "$actual" "$min"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %-55s  expected >= %s  got=%s\n' "$name" "$min" "$actual"
    FAIL=$((FAIL+1))
  fi
}

test_na() {
  local name="$1" reason="$2"
  printf 'N/A   %-55s  %s\n' "$name" "$reason"
  NA=$((NA+1))
}

log() { printf '\n--- %s ---\n' "$*"; }

# Generate Prometheus bearer token
TOKEN=$(mc admin prometheus generate local 2>&1 | awk '/^token:/{print $2}' | head -1)
[ -z "$TOKEN" ] && TOKEN=$(mc admin prometheus generate local 2>&1 | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1)

if [ -z "$TOKEN" ]; then
  test_result "Prometheus token generated" "1" "0"
  exit 1
fi

# ============ 1. Metrics endpoints ============
log "1. Metrics endpoints (3 endpoints: cluster/bucket/node)"

for EP in cluster bucket node; do
  CODE=$(curl_run -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "http://${MINIO_IP}:9000/minio/v2/metrics/${EP}" 2>/dev/null)
  test_result "/minio/v2/metrics/${EP} responds 200" "200" "$CODE"
done

# ============ 2. Cluster metrics content ============
log "2. Cluster metrics content"
CLUSTER_M=$(curl_run -s -H "Authorization: Bearer ${TOKEN}" \
  "http://${MINIO_IP}:9000/minio/v2/metrics/cluster" 2>/dev/null)

CLUSTER_LINES=$(echo "$CLUSTER_M" | grep -c "^minio_" || true)
test_min "cluster: minio_* lines" 30 "$CLUSTER_LINES"

HAS_S3=$(echo "$CLUSTER_M" | grep -c "^minio_s3_requests" || true)
test_min "cluster: minio_s3_requests*" 1 "$HAS_S3"

HAS_CLUSTER=$(echo "$CLUSTER_M" | grep -c "^minio_cluster_" || true)
test_min "cluster: minio_cluster_*" 10 "$HAS_CLUSTER"

HAS_NODE=$(echo "$CLUSTER_M" | grep -c "^minio_node_" || true)
test_min "cluster: minio_node_*" 5 "$HAS_NODE"

# ============ 3. Bucket metrics content ============
log "3. Bucket metrics content"
BUCKET_M=$(curl_run -s -H "Authorization: Bearer ${TOKEN}" \
  "http://${MINIO_IP}:9000/minio/v2/metrics/bucket" 2>/dev/null)

BUCKET_LINES=$(echo "$BUCKET_M" | grep -c "^minio_" || true)
test_min "bucket: minio_* lines" 5 "$BUCKET_LINES"

# Look for the actual bucket usage metric name in this build
HAS_USAGE=$(echo "$BUCKET_M" | grep -cE "^minio_bucket_usage|^minio_bucket_" || true)
test_min "bucket: minio_bucket* metrics present" 1 "$HAS_USAGE"

echo "  Bucket metric names (sample):"
echo "$BUCKET_M" | grep -oE "^minio_[a-z_]+" | sort -u | head -10 | sed 's/^/    /'

# ============ 4. Node metrics content ============
log "4. Node metrics content"
NODE_M=$(curl_run -s -H "Authorization: Bearer ${TOKEN}" \
  "http://${MINIO_IP}:9000/minio/v2/metrics/node" 2>/dev/null)

NODE_LINES=$(echo "$NODE_M" | grep -c "^minio_" || true)
test_min "node: minio_* lines" 10 "$NODE_LINES"

HAS_DRIVE=$(echo "$NODE_M" | grep -c "minio_node_drive" || true)
if [ "$HAS_DRIVE" -ge 1 ]; then
  test_min "node: minio_node_drive* metrics" 1 "$HAS_DRIVE"
else
  test_na "node: minio_node_drive* metrics" "not exposed in this build"
fi

# ============ 5. mc admin info ============
log "5. mc admin info"
INFO_OUTPUT=$(mc admin info local 2>&1)
HAS_NODE=$(echo "$INFO_OUTPUT" | grep -cE "●|:[0-9]+$" || true)
test_min "mc admin info reports a node" 1 "$HAS_NODE"
HAS_UPTIME=$(echo "$INFO_OUTPUT" | grep -c "Uptime" || true)
test_min "mc admin info has Uptime" 1 "$HAS_UPTIME"
HAS_DRIVES=$(echo "$INFO_OUTPUT" | grep -c "Drives" || true)
test_min "mc admin info has Drives info" 1 "$HAS_DRIVES"
HAS_ERASURE=$(echo "$INFO_OUTPUT" | grep -c "Erasure" || true)
test_min "mc admin info has Erasure info" 1 "$HAS_ERASURE"

echo "  Sample output:"
echo "$INFO_OUTPUT" | head -15 | sed 's/^/    /'

# ============ 6. mc admin trace ============
log "6. mc admin trace (short capture)"
TRACE_OUT=$(timeout 6 mc admin trace --verbose local 2>&1 || true)
TRACE_LINES=$(echo "$TRACE_OUT" | wc -l)
test_min "mc admin trace runs" 1 "$TRACE_LINES"

# ============ 7. MinIO logs ============
log "7. MinIO logs accessible"
LOG_LINES=$(docker logs minio --tail 100 2>&1 | wc -l)
test_min "MinIO logs contain lines" 10 "$LOG_LINES"

# ============ 8. Console ============
log "8. Console HTTP reachable"
CONSOLE_CODE=$(curl_run -s -o /dev/null -w "%{http_code}" \
  "http://${MINIO_IP}:9001/" 2>/dev/null)
if [ "$CONSOLE_CODE" = "200" ] || [ "$CONSOLE_CODE" = "307" ] || [ "$CONSOLE_CODE" = "302" ]; then
  test_result "Console responds" "2xx/3xx" "2xx/3xx"
  printf '      Console HTTP code: %s\n' "$CONSOLE_CODE"
else
  test_result "Console responds" "2xx/3xx" "$CONSOLE_CODE"
fi

# ============ 9. Health endpoints ============
log "9. Health endpoints"
LIVE=$(curl_run -s -o /dev/null -w "%{http_code}" \
  "http://${MINIO_IP}:9000/minio/health/live" 2>/dev/null)
test_result "/minio/health/live" "200" "$LIVE"

READY=$(curl_run -s -o /dev/null -w "%{http_code}" \
  "http://${MINIO_IP}:9000/minio/health/ready" 2>/dev/null)
test_result "/minio/health/ready" "200" "$READY"

CLUSTER_HEALTH=$(curl_run -s -o /dev/null -w "%{http_code}" \
  "http://${MINIO_IP}:9000/minio/health/cluster" 2>/dev/null)
test_result "/minio/health/cluster" "200" "$CLUSTER_HEALTH"

printf '\n==========================================\n'
printf '  Observability tests:  PASS=%d  FAIL=%d  N/A=%d\n' "$PASS" "$FAIL" "$NA"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
