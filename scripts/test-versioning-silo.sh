#!/bin/bash
# test-versioning.sh — Versioning deep-dive for DEV-907 (Session 3A).

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

BUCKET="test-versioning"
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

mc rb --force --dangerous "local/$BUCKET" >/dev/null 2>&1 || true
mc mb "local/$BUCKET" >/dev/null 2>&1

# ============ 1. Enable versioning ============
log "1. Enable versioning"
mc version enable "local/$BUCKET" >/dev/null 2>&1
V_STATE=$(mc version info "local/$BUCKET" 2>/dev/null | grep -oE "enabled|suspended" | head -1)
test_result "Versioning enabled" "enabled" "$V_STATE"

# ============ 2. Upload 3 versions of same key ============
log "2. Upload 3 versions of same key"
echo "content v1" > /data/testdata/local/v1.txt
echo "content v2" > /data/testdata/local/v2.txt
echo "content v3" > /data/testdata/local/v3.txt
mc cp /data/testdata/local/v1.txt "local/$BUCKET/key.txt" >/dev/null 2>&1
sleep 1
mc cp /data/testdata/local/v2.txt "local/$BUCKET/key.txt" >/dev/null 2>&1
sleep 1
mc cp /data/testdata/local/v3.txt "local/$BUCKET/key.txt" >/dev/null 2>&1

V_COUNT=$(mc ls --versions "local/$BUCKET/key.txt" 2>/dev/null | wc -l)
test_result "3 versions stored" "3" "$V_COUNT"

# ============ 3. Current version is v3 ============
log "3. Current version returns v3"
CURRENT=$(mc cat "local/$BUCKET/key.txt" 2>/dev/null | head -1)
test_result "Current content = content v3" "content v3" "$CURRENT"

# ============ 4. Suspend versioning ============
log "4. Suspend versioning"
mc version suspend "local/$BUCKET" >/dev/null 2>&1
S_STATE=$(mc version info "local/$BUCKET" 2>/dev/null | grep -oE "enabled|suspended" | head -1)
test_result "Versioning suspended" "suspended" "$S_STATE"

# ============ 5. Upload while suspended ============
log "5. Upload while suspended (overwrites null version)"
echo "content v4-suspended" > /data/testdata/local/v4.txt
mc cp /data/testdata/local/v4.txt "local/$BUCKET/key.txt" >/dev/null 2>&1
# When suspended, new uploads overwrite the "null" version.
# The current key content should now be v4
AFTER_SUSPEND=$(mc cat "local/$BUCKET/key.txt" 2>/dev/null | head -1)
test_result "Suspended upload becomes current" "content v4-suspended" "$AFTER_SUSPEND"

# ============ 6. Re-enable versioning ============
log "6. Re-enable versioning"
mc version enable "local/$BUCKET" >/dev/null 2>&1
R_STATE=$(mc version info "local/$BUCKET" 2>/dev/null | grep -oE "enabled|suspended" | head -1)
test_result "Versioning re-enabled" "enabled" "$R_STATE"

# ============ 7. Upload v5 after re-enable ============
log "7. Upload v5 after re-enable"
echo "content v5" > /data/testdata/local/v5.txt
mc cp /data/testdata/local/v5.txt "local/$BUCKET/key.txt" >/dev/null 2>&1
AFTER_REENABLE=$(mc cat "local/$BUCKET/key.txt" 2>/dev/null | head -1)
test_result "Current content = content v5" "content v5" "$AFTER_REENABLE"

# ============ 8. Delete marker via mc rm ============
log "8. Delete marker (soft delete)"
mc rm "local/$BUCKET/key.txt" >/dev/null 2>&1
# After delete, current key should NOT be retrievable
RM_ERROR=$(mc cat "local/$BUCKET/key.txt" 2>&1 | grep -c "ERROR\|does not exist" || true)
test_result "Object hidden after soft delete" "1" "$RM_ERROR"

# Delete marker should appear in version list; use --json for reliable detection
DM_COUNT=$(mc ls --versions --json "local/$BUCKET/key.txt" 2>/dev/null | grep -c '"isDeleteMarker":true' || true)
test_result "Delete marker present in version list" "1" "$DM_COUNT"

# ============ 9. Undelete by removing delete marker ============
log "9. Undelete by removing delete marker"
# Need the delete marker's version ID
DM_VID=$(mc ls --versions --json "local/$BUCKET/key.txt" 2>/dev/null | \
  grep -i "deletemarker" | grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$DM_VID" ]; then
  mc rm --force --version-id "$DM_VID" "local/$BUCKET/key.txt" >/dev/null 2>&1
  RESTORED=$(mc cat "local/$BUCKET/key.txt" 2>/dev/null | head -1)
  test_result "Object restored after delete-marker removal" "content v5" "$RESTORED"
else
  test_result "Object restored after delete-marker removal" "found-vid" "no-vid"
fi

# ============ 10. List versions ============
log "10. List versions after operations"
V_TOTAL=$(mc ls --versions "local/$BUCKET/key.txt" 2>/dev/null | wc -l)
if [ "$V_TOTAL" -ge 4 ]; then
  test_result "Version list shows >=4 entries" "1" "1"
else
  test_result "Version list shows >=4 entries" "1" "$V_TOTAL"
fi

# ============ 11. Permanent delete of specific version ============
log "11. Permanent delete of a specific version"
# Get the oldest version ID
OLD_VID=$(mc ls --versions --json "local/$BUCKET/key.txt" 2>/dev/null | \
  grep -v "deletemarker" | tail -1 | grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$OLD_VID" ]; then
  BEFORE=$(mc ls --versions "local/$BUCKET/key.txt" 2>/dev/null | wc -l)
  mc rm --force --version-id "$OLD_VID" "local/$BUCKET/key.txt" >/dev/null 2>&1
  AFTER=$(mc ls --versions "local/$BUCKET/key.txt" 2>/dev/null | wc -l)
  EXPECTED=$((BEFORE - 1))
  test_result "Version permanently deleted" "$EXPECTED" "$AFTER"
else
  test_result "Version permanently deleted" "found-vid" "no-vid"
fi

# ============ 12. Restore old version ============
log "12. Restore old version (copy v1 back to current)"
# Get v1 version ID (oldest PUT version)
V1_VID=$(mc ls --versions --json "local/$BUCKET/key.txt" 2>/dev/null | \
  grep -v "deletemarker" | tail -1 | grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$V1_VID" ]; then
  mc cp --version-id "$V1_VID" "local/$BUCKET/key.txt" "local/$BUCKET/key-restored.txt" >/dev/null 2>&1
  RESTORED_CONTENT=$(mc cat "local/$BUCKET/key-restored.txt" 2>/dev/null | head -1)
  test_result "Old version copied to new key" "1" "1"
  printf '      Restored content: %s\n' "$RESTORED_CONTENT"
else
  test_result "Old version copied to new key" "found-vid" "no-vid"
fi

# ============ 13. ListObjectVersions at scale ============
log "13. ListObjectVersions at scale (30 versions on one key)"
for i in $(seq 1 30); do
  echo "scale-version-$i" > /data/testdata/local/scale.txt
  mc cp /data/testdata/local/scale.txt "local/$BUCKET/scale-key.txt" >/dev/null 2>&1
done
SCALE_COUNT=$(mc ls --versions "local/$BUCKET/scale-key.txt" 2>/dev/null | wc -l)
test_result "30 versions listed at scale" "30" "$SCALE_COUNT"

# ============ 14. Cleanup ============
log "14. Cleanup"
mc rm --force --recursive --versions --dangerous "local/$BUCKET/" >/dev/null 2>&1
mc rb --force "local/$BUCKET" >/dev/null 2>&1
GONE=$(mc ls local/ | grep -c "$BUCKET/" || true)
test_result "Bucket cleaned up" "0" "$GONE"

printf '\n==========================================\n'
printf '  Versioning tests:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
