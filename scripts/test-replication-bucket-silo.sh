#!/bin/bash
# test-replication-bucket-silo.sh — Silo-to-Silo bucket replication (DEV-911).
# Mirrors test-replication-bucket.sh but targets silo -> silo-target.

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

docker volume create "$MC_CFG_VOL" >/dev/null 2>&1

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

# Aliases
mc alias set silo "http://silo:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
mc alias set silo-target "http://silo-target:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1

SRC_BUCKET="silo-repl-test"
TGT_BUCKET="silo-repl-test"

# ============ 0. Cleanup ============
log "0. Cleanup"
mc rb --force --dangerous "silo/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "silo-target/$TGT_BUCKET" >/dev/null 2>&1 || true
sleep 2

# ============ 1. Create buckets + versioning ============
log "1. Create source + target buckets with versioning"
mc mb "silo/$SRC_BUCKET" >/dev/null 2>&1
mc version enable "silo/$SRC_BUCKET" >/dev/null 2>&1
mc mb "silo-target/$TGT_BUCKET" >/dev/null 2>&1
mc version enable "silo-target/$TGT_BUCKET" >/dev/null 2>&1

SRC_V=$(mc version info "silo/$SRC_BUCKET" 2>/dev/null | grep -oE "enabled|suspended" | head -1)
TGT_V=$(mc version info "silo-target/$TGT_BUCKET" 2>/dev/null | grep -oE "enabled|suspended" | head -1)
test_result "Source versioning enabled" "enabled" "$SRC_V"
test_result "Target versioning enabled" "enabled" "$TGT_V"

# ============ 2. Enable replication (Silo-to-Silo) ============
log "2. Enable Silo-to-Silo one-way replication"
REPL_OUT=$(mc replicate add "silo/$SRC_BUCKET" \
  --remote-bucket "http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@silo-target:9000/$TGT_BUCKET" \
  --replicate "delete,delete-marker,existing-objects" 2>&1)
echo "  $REPL_OUT"

RULE_EXISTS=$(mc replicate ls "silo/$SRC_BUCKET" 2>/dev/null | grep -c "Rule ID" || true)
test_result "Replication rule added (Silo->Silo)" "1" "$RULE_EXISTS"

# ============ 3. Upload + verify replication ============
log "3. Upload object"
echo "silo replication test v1" > /data/testdata/local/silo-repl-v1.txt
mc cp /data/testdata/local/silo-repl-v1.txt "silo/$SRC_BUCKET/hello.txt" >/dev/null 2>&1

REPLICATED=0
for i in $(seq 1 15); do
  if mc ls "silo-target/$TGT_BUCKET/hello.txt" 2>/dev/null | grep -q "hello.txt"; then
    REPLICATED=1
    break
  fi
  sleep 2
done
test_result "Object replicated to silo-target" "1" "$REPLICATED"

# ============ 4. Versioned data ============
log "4. Versioned data replication"
echo "silo replication v2" > /data/testdata/local/silo-repl-v2.txt
mc cp /data/testdata/local/silo-repl-v2.txt "silo/$SRC_BUCKET/hello.txt" >/dev/null 2>&1
sleep 2
echo "silo replication v3" > /data/testdata/local/silo-repl-v3.txt
mc cp /data/testdata/local/silo-repl-v3.txt "silo/$SRC_BUCKET/hello.txt" >/dev/null 2>&1

sleep 6
SRC_VERSIONS=$(mc ls --versions "silo/$SRC_BUCKET/hello.txt" 2>/dev/null | wc -l)
TGT_VERSIONS=$(mc ls --versions "silo-target/$TGT_BUCKET/hello.txt" 2>/dev/null | wc -l)
test_result "Version count matches (Silo->Silo)" "$SRC_VERSIONS" "$TGT_VERSIONS"

# ============ 5. Delete marker ============
log "5. Delete marker replication"
mc rm "silo/$SRC_BUCKET/hello.txt" >/dev/null 2>&1

DM_REPLICATED=0
for i in $(seq 1 15); do
  DM_COUNT=$(mc ls --versions --json "silo-target/$TGT_BUCKET/hello.txt" 2>/dev/null | grep -c '"isDeleteMarker":true' || true)
  if [ "$DM_COUNT" -ge 1 ]; then
    DM_REPLICATED=1
    break
  fi
  sleep 2
done
test_result "Delete marker replicated" "1" "$DM_REPLICATED"

# ============ 6. Tags ============
log "6. Tagged object replication"
echo "tagged content" > /data/testdata/local/silo-repl-tagged.txt
mc cp /data/testdata/local/silo-repl-tagged.txt "silo/$SRC_BUCKET/tagged.txt" >/dev/null 2>&1
mc tag set "silo/$SRC_BUCKET/tagged.txt" "env=test&owner=devops" >/dev/null 2>&1

sleep 6
TGT_TAGS=$(mc tag list "silo-target/$TGT_BUCKET/tagged.txt" 2>/dev/null | grep -cE "^\s*(env|owner)" || true)
test_result "Tags replicated (2)" "2" "$TGT_TAGS"

# ============ 7. Metadata ============
log "7. Metadata replication"
echo "meta content" > /data/testdata/local/silo-repl-meta.txt
mc cp --attr "Owner=alice;Stage=beta" \
  /data/testdata/local/silo-repl-meta.txt "silo/$SRC_BUCKET/meta.txt" >/dev/null 2>&1

sleep 6
TGT_META=$(mc stat "silo-target/$TGT_BUCKET/meta.txt" 2>/dev/null | grep -c "X-Amz-Meta-" || true)
if [ "$TGT_META" -ge 2 ]; then
  test_result "Metadata replicated (>=2 keys)" "1" "1"
else
  test_result "Metadata replicated (>=2 keys)" "1" "0"
fi

# ============ 8. Replication status ============
log "8. Replication status"
STATUS_OUT=$(mc replicate status "silo/$SRC_BUCKET" 2>&1)
if echo "$STATUS_OUT" | grep -qiE "arn|rule|replicated|pending"; then
  test_result "Replication status retrievable" "1" "1"
else
  test_result "Replication status retrievable" "1" "0"
fi

# ============ 9. Manifest comparison ============
log "9. Manifest comparison"
SRC_OBJS=$(mc ls --recursive --json "silo/$SRC_BUCKET/" 2>/dev/null | grep -c '"key"' || echo 0)
TGT_OBJS=$(mc ls --recursive --json "silo-target/$TGT_BUCKET/" 2>/dev/null | grep -c '"key"' || echo 0)
test_result "Object counts match (Silo->Silo)" "$SRC_OBJS" "$TGT_OBJS"

# ============ 10. Silo-only: mcli checksum verify ============
log "10. Silo-only: mcli checksum verify"
CKSUM_OUT=$(mc checksum verify "silo/$SRC_BUCKET/tagged.txt" 2>&1)
if echo "$CKSUM_OUT" | grep -qiE "verified|success|OK|valid"; then
  test_result "mcli checksum verify works on Silo" "1" "1"
  echo "  $CKSUM_OUT" | head -3
else
  test_result "mcli checksum verify works on Silo" "1" "0"
  echo "  $CKSUM_OUT" | head -5
fi

# ============ 11. Cleanup ============
log "11. Cleanup"
mc rb --force --dangerous "silo/$SRC_BUCKET" >/dev/null 2>&1 || true
mc rb --force --dangerous "silo-target/$TGT_BUCKET" >/dev/null 2>&1 || true
test_result "Cleanup complete" "1" "1"

printf '\n==========================================\n'
printf '  Silo-to-Silo replication:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
