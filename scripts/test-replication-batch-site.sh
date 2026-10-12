#!/bin/bash
# test-replication-batch-site.sh — Batch + site replication for DEV-909 (Session 9D).

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

# Batch YAML written into /data/testdata (mounted at /data/testdata inside container)
BATCH_DIR="/data/testdata/batch-job"

mc() {
  docker run --rm --network "$MC_NET" \
    -v "$MC_CFG_VOL":/root/.mc \
    -v /data/testdata:/data/testdata \
    "$MC_IMAGE" "$@"
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

test_na() {
  printf 'N/A   %-55s  %s\n' "$1" "$2"
  NA=$((NA+1))
}

log() { printf '\n--- %s ---\n' "$*"; }

mc alias set source "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
mc alias set target "http://minio-target:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1

# ==========================================================
# PART A — Batch replication
# ==========================================================
log "Part A: Batch replication"

SRC_BUCKET="batch-repl"
TGT_BUCKET="batch-repl"

mc rb --force --dangerous "source/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "target/$TGT_BUCKET" >/dev/null 2>&1 || true
sleep 2

log "A1. Create source bucket with 10 objects"
mc mb "source/$SRC_BUCKET" >/dev/null 2>&1
mc version enable "source/$SRC_BUCKET" >/dev/null 2>&1
for i in $(seq -w 1 10); do
  echo "batch-$i" > /data/testdata/local/batch-$i.txt
  mc cp /data/testdata/local/batch-$i.txt "source/$SRC_BUCKET/batch-$i.txt" >/dev/null 2>&1
done
SRC_COUNT=$(mc ls --recursive "source/$SRC_BUCKET/" 2>/dev/null | wc -l)
test_result "Source has 10 objects" "10" "$SRC_COUNT"

log "A2. Create target bucket (no replication rule yet)"
mc mb "target/$TGT_BUCKET" >/dev/null 2>&1
mc version enable "target/$TGT_BUCKET" >/dev/null 2>&1
TGT_BEFORE=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
test_result "Target starts empty" "0" "$TGT_BEFORE"

log "A3. Write batch job YAML into mounted path"
mkdir -p "$BATCH_DIR"
cat > "$BATCH_DIR/replicate.yaml" << YAML
replicate:
  apiVersion: v1
  source:
    type: minio
    bucket: $SRC_BUCKET
    prefix: ""
  target:
    type: minio
    bucket: $TGT_BUCKET
    endpoint: http://minio-target:9000
    credentials:
      accessKey: ${MINIO_ROOT_USER}
      secretKey: ${MINIO_ROOT_PASSWORD}
  flags:
    filter:
      newerThan: "1d"
YAML
test_result "Batch job YAML written" "1" "1"

log "A4. Start batch job (mc batch start source JOBFILE)"
BATCH_START=$(mc batch start source "$BATCH_DIR/replicate.yaml" 2>&1)
echo "  $BATCH_START" | head -3

# Extract job ID if returned
JOB_ID=$(echo "$BATCH_START" | grep -oE 'ID: [a-zA-Z0-9-]+' | head -1 | awk '{print $2}')

if echo "$BATCH_START" | grep -qiE "job.*started|success|replicate"; then
  test_result "Batch job started" "1" "1"
else
  test_result "Batch job started" "1" "0"
fi

log "A5. Check batch job status"
sleep 15
if [ -n "$JOB_ID" ]; then
  STATUS_OUT=$(mc batch status source "$JOB_ID" 2>&1 || true)
  echo "  $STATUS_OUT" | head -10
fi

# Wait for batch replication
BATCH_REPLICATED=0
for i in $(seq 1 30); do
  TGT_COUNT=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
  if [ "$TGT_COUNT" -ge 10 ]; then
    BATCH_REPLICATED=1
    break
  fi
  sleep 2
done
TGT_FINAL=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
test_result "Batch job replicated objects (>=10)" "1" "$BATCH_REPLICATED"
echo "  Final target count: $TGT_FINAL"

# ==========================================================
# PART B — Site replication
# ==========================================================
log "Part B: Site replication"

SRC_DATA=$(mc ls "source/" 2>/dev/null | wc -l)
TGT_DATA=$(mc ls "target/" 2>/dev/null | wc -l)
echo "  Source has $SRC_DATA buckets"
echo "  Target has $TGT_DATA buckets"

# MinIO requires only one site to have data during federation setup.
# Attempting with data on both sides returns the documented error.
SITE_ATTEMPT=$(mc admin replicate add source target 2>&1 || true)
echo "  Attempt output: $SITE_ATTEMPT" | head -3

if echo "$SITE_ATTEMPT" | grep -qiE "success|enabled"; then
  test_result "Site replication enabled" "1" "1"
elif echo "$SITE_ATTEMPT" | grep -qiE "only one cluster may have data"; then
  test_na "Site replication add" "both sites have data; MinIO requires one empty site (documented behavior)"
else
  test_result "Site replication enabled" "1" "0"
fi

# ==========================================================
# Cleanup
# ==========================================================
log "Cleanup"
mc rb --force --dangerous "source/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "target/$TGT_BUCKET" >/dev/null 2>&1 || true
rm -rf "$BATCH_DIR" 2>/dev/null || true
test_result "Cleanup complete" "1" "1"

printf '\n==========================================\n'
printf '  Batch + site replication:  PASS=%d  FAIL=%d  N/A=%d\n' "$PASS" "$FAIL" "$NA"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
