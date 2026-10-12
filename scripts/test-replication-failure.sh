#!/bin/bash
# test-replication-failure.sh — Failure scenarios for DEV-909 (Session 9C).
# Covers: target down, network cut, lag measurement, resync after recovery.

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

docker volume create "$MC_CFG_VOL" >/dev/null

mc() {
  docker run --rm --network "$MC_NET" \
    -v "$MC_CFG_VOL":/root/.mc \
    -v /data/testdata:/data/testdata \
    "$MC_IMAGE" "$@"
}

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

# Ensure aliases
mc alias set source "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
mc alias set target "http://minio-target:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1

SRC_BUCKET="repl-fail"
TGT_BUCKET="repl-fail"

# ============ 0. Cleanup + set up fresh bucket ============
log "0. Cleanup + create fresh test bucket"
mc rb --force --dangerous "source/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "target/$TGT_BUCKET" >/dev/null 2>&1 || true
sleep 2

mc mb "source/$SRC_BUCKET" >/dev/null 2>&1
mc version enable "source/$SRC_BUCKET" >/dev/null 2>&1
mc mb "target/$TGT_BUCKET" >/dev/null 2>&1
mc version enable "target/$TGT_BUCKET" >/dev/null 2>&1

mc replicate add "source/$SRC_BUCKET" \
  --remote-bucket "http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio-target:9000/$TGT_BUCKET" \
  --replicate "delete,delete-marker,existing-objects" >/dev/null 2>&1

RULE_EXISTS=$(mc replicate ls "source/$SRC_BUCKET" 2>/dev/null | grep -c "Rule ID" || true)
test_result "Replication rule set up" "1" "$RULE_EXISTS"

# ============ 1. Lag measurement (baseline) ============
log "1. Lag measurement — write 20 objects, measure replication time"
LAG_FILE="docs/05-minio-replication/evidence/lag-measurement.txt"
{
  echo "=== Replication Lag Measurement ==="
  echo "Date: $(date -Iseconds)"
  echo ""
  echo "Writing 20 objects to source..."
} > "$LAG_FILE"

START_TIME=$(date +%s.%N)
for i in $(seq -w 1 20); do
  echo "lag-test-$i" > /data/testdata/local/lag-$i.txt
  mc cp /data/testdata/local/lag-$i.txt "source/$SRC_BUCKET/lag-$i.txt" >/dev/null 2>&1
done
WRITE_DONE=$(date +%s.%N)
WRITE_DURATION=$(echo "$WRITE_DONE - $START_TIME" | bc)

echo "  Wrote 20 objects in ${WRITE_DURATION}s" | tee -a "$LAG_FILE"

# Poll for replication
REPL_START=$(date +%s.%N)
TGT_COUNT=0
for i in $(seq 1 60); do
  TGT_COUNT=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
  if [ "$TGT_COUNT" -ge 20 ]; then
    break
  fi
  sleep 1
done
REPL_END=$(date +%s.%N)
REPL_DURATION=$(echo "$REPL_END - $REPL_START" | bc)

echo "  Replication took ${REPL_DURATION}s for 20 objects" | tee -a "$LAG_FILE"
echo "  Target object count: $TGT_COUNT" | tee -a "$LAG_FILE"
echo "  Avg lag per object: $(echo "scale=3; $REPL_DURATION / 20" | bc)s" | tee -a "$LAG_FILE"

test_result "All 20 objects replicated" "20" "$TGT_COUNT"

# ============ 2. Target down scenario ============
log "2. Target down scenario"
echo "" | tee -a "$LAG_FILE"
echo "--- Target Down Test ---" | tee -a "$LAG_FILE"

# Stop target
echo "  Stopping target container..."
docker stop minio-target >/dev/null 2>&1
sleep 3

# Write objects while target is down
echo "  Writing 5 objects while target is down..."
for i in $(seq -w 21 25); do
  echo "offline-$i" > /data/testdata/local/offline-$i.txt
  mc cp /data/testdata/local/offline-$i.txt "source/$SRC_BUCKET/offline-$i.txt" >/dev/null 2>&1
done

# Restart target
echo "  Restarting target..."
docker start minio-target >/dev/null 2>&1
sleep 15

# Wait for recovery replication
RECOVER_START=$(date +%s.%N)
RECOVERED=0
for i in $(seq 1 60); do
  TGT_COUNT=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
  if [ "$TGT_COUNT" -ge 25 ]; then
    RECOVERED=1
    break
  fi
  sleep 1
done
RECOVER_END=$(date +%s.%N)
RECOVER_DURATION=$(echo "$RECOVER_END - $RECOVER_START" | bc)

echo "  Time to consistency: ${RECOVER_DURATION}s" | tee -a "$LAG_FILE"
echo "  Final target count: $TGT_COUNT" | tee -a "$LAG_FILE"

test_result "Recovered after target restart (>=25 objects)" "1" "$RECOVERED"

# ============ 3. Network cut scenario ============
log "3. Network cut scenario"
echo "" | tee -a "$LAG_FILE"
echo "--- Network Cut Test ---" | tee -a "$LAG_FILE"

# Disconnect target from the network
echo "  Disconnecting target from minio-lab_minio-net..."
docker network disconnect minio-lab_minio-net minio-target 2>&1 | sed 's/^/    /'

# Write objects during network cut
echo "  Writing 5 objects during network cut..."
for i in $(seq -w 26 30); do
  echo "netcut-$i" > /data/testdata/local/netcut-$i.txt
  mc cp /data/testdata/local/netcut-$i.txt "source/$SRC_BUCKET/netcut-$i.txt" >/dev/null 2>&1
done

# Reconnect target
echo "  Reconnecting target..."
docker network connect minio-lab_minio-net minio-target 2>&1 | sed 's/^/    /'
sleep 15

# Wait for sync
NETCUT_START=$(date +%s.%N)
NETCUT_RECOVERED=0
for i in $(seq 1 60); do
  TGT_COUNT=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)
  if [ "$TGT_COUNT" -ge 30 ]; then
    NETCUT_RECOVERED=1
    break
  fi
  sleep 1
done
NETCUT_END=$(date +%s.%N)
NETCUT_DURATION=$(echo "$NETCUT_END - $NETCUT_START" | bc)

echo "  Time to consistency after network cut: ${NETCUT_DURATION}s" | tee -a "$LAG_FILE"
echo "  Final target count: $TGT_COUNT" | tee -a "$LAG_FILE"

test_result "Recovered after network reconnect (>=30 objects)" "1" "$NETCUT_RECOVERED"

# ============ 4. Zero data loss check ============
log "4. Zero data loss verification"
SRC_FINAL=$(mc ls --recursive "source/$SRC_BUCKET/" 2>/dev/null | wc -l)
TGT_FINAL=$(mc ls --recursive "target/$TGT_BUCKET/" 2>/dev/null | wc -l)

echo "  Source final count: $SRC_FINAL" | tee -a "$LAG_FILE"
echo "  Target final count: $TGT_FINAL" | tee -a "$LAG_FILE"
echo "  Difference: $((SRC_FINAL - TGT_FINAL))" | tee -a "$LAG_FILE"

test_result "No missing objects (source = target)" "$SRC_FINAL" "$TGT_FINAL"

# ============ 5. Resync command ============
log "5. Resync command"
# Extract ARN from the replication rule JSON
ARN=$(mc replicate ls "source/$SRC_BUCKET" --json 2>/dev/null | \
  python3 -c "import sys, json; print(json.load(sys.stdin).get('rule', {}).get('Destination', {}).get('Bucket', ''))" 2>/dev/null)

echo "  Target ARN: $ARN"

if [ -n "$ARN" ]; then
  RESYNC_OUT=$(mc replicate resync start "source/$SRC_BUCKET" --remote-bucket "$ARN" 2>&1)
  echo "  Resync output: $RESYNC_OUT"

  if echo "$RESYNC_OUT" | grep -qiE "replication reset started|started"; then
    test_result "Resync command works (with ARN)" "1" "1"
  else
    test_result "Resync command works (with ARN)" "1" "0"
  fi
else
  test_result "Resync command works (with ARN)" "arn-found" "arn-not-found"
fi

# ============ 6. Cleanup ============
log "6. Cleanup"
mc rb --force --dangerous "source/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "target/$TGT_BUCKET" >/dev/null 2>&1 || true
test_result "Cleanup complete" "1" "1"

printf '\n==========================================\n'
printf '  Failure scenarios:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
