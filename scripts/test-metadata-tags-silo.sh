#!/bin/bash
# test-metadata-tags.sh — Metadata and tagging tests for DEV-907.
# Covers: user metadata (X-Amz-Meta-*), object tags, bucket tags.

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

BUCKET="test-metadata"
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
mc mb "local/$BUCKET" >/dev/null 2>&1

# ============ 1. User metadata on PUT ============
# mcli: --attr "key1=value1;key2=value2"  (semicolons, no X-Amz-Meta- prefix)
log "1. User metadata (X-Amz-Meta-*)"
echo "content-for-metadata" > /data/testdata/local/meta-test.txt
mc cp --attr "Owner=alice;Project=demo;Stage=beta" \
  /data/testdata/local/meta-test.txt \
  "local/$BUCKET/meta-1.txt" >/dev/null 2>&1

META_COUNT=$(mc stat "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -c "X-Amz-Meta-")
test_result "User metadata keys present (3)" "3" "$META_COUNT"

# ============ 2. Object tags ============
log "2. Object tags"
mc tag set "local/$BUCKET/meta-1.txt" "env=test&team=devops&priority=high" >/dev/null 2>&1
TAG_COUNT=$(mc tag list "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -cE "^[a-z]+ +:")
test_result "Object tags set (3)" "3" "$TAG_COUNT"

# ============ 3. Verify specific tag value ============
log "3. Verify tag value"
TAG_ENV=$(mc tag list "local/$BUCKET/meta-1.txt" 2>/dev/null | awk '/^env/{print $3}' | head -1)
test_result "Tag env value = test" "test" "$TAG_ENV"

# ============ 4. Bucket tags ============
log "4. Bucket tags"
mc tag set "local/$BUCKET" "department=engineering&cost-center=CC-42" >/dev/null 2>&1
BTAG_COUNT=$(mc tag list "local/$BUCKET" 2>/dev/null | grep -cE "^[a-z-]+ +:")
test_result "Bucket tags set (2)" "2" "$BTAG_COUNT"

# ============ 5. Update existing tag ============
log "5. Update existing object tag"
mc tag set "local/$BUCKET/meta-1.txt" "priority=critical" >/dev/null 2>&1
NEW_PRIORITY=$(mc tag list "local/$BUCKET/meta-1.txt" 2>/dev/null | awk '/^priority/{print $3}' | head -1)
test_result "Tag updated to critical" "critical" "$NEW_PRIORITY"

# ============ 6. Remove one tag by re-setting remaining set ============
log "6. Remove one tag (re-set remaining tags)"
# mcli tag remove removes ALL tags; to remove just one, re-apply the others
mc tag set "local/$BUCKET/meta-1.txt" "env=test&team=devops" >/dev/null 2>&1
AFTER_REMOVE=$(mc tag list "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -cE "^[a-z]+ +:")
test_result "Tag removed (2 remaining)" "2" "$AFTER_REMOVE"

# ============ 6b. Verify priority is gone ============
log "6b. Verify 'priority' tag is gone"
PRIORITY_GONE=$(mc tag list "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -c "^priority" || true)
test_result "Priority tag removed" "0" "$PRIORITY_GONE"

# ============ 7. Verify user metadata persisted ============
log "7. User metadata survives tag operations"
META_STILL=$(mc stat "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -c "X-Amz-Meta-")
test_result "Metadata still present after tag ops" "3" "$META_STILL"

# ============ 8. Copy preserves metadata ============
log "8. Server-side copy preserves metadata"
mc cp "local/$BUCKET/meta-1.txt" "local/$BUCKET/meta-1-copy.txt" >/dev/null 2>&1
COPY_META=$(mc stat "local/$BUCKET/meta-1-copy.txt" 2>/dev/null | grep -c "X-Amz-Meta-")
# Note: MinIO adds X-Amz-Meta-X-Amz-Tagging-Count on copy of tagged objects.
# We check >= 3 to confirm original metadata is preserved.
if [ "$COPY_META" -ge 3 ]; then
  test_result "Copy preserves metadata (>=3 keys)" "1" "1"
  printf '      INFO: metadata keys on copy = %s (extra = MinIO tagging-count header)\n' "$COPY_META"
else
  test_result "Copy preserves metadata (>=3 keys)" "1" "0"
fi

# ============ 9. Overwrite resets metadata ============
log "9. Overwrite resets metadata (S3 semantics)"
echo "new-content" > /data/testdata/local/overwrite.txt
mc cp /data/testdata/local/overwrite.txt "local/$BUCKET/meta-1.txt" >/dev/null 2>&1
AFTER_OVERWRITE=$(mc stat "local/$BUCKET/meta-1.txt" 2>/dev/null | grep -c "X-Amz-Meta-")
test_result "Overwrite cleared old metadata" "0" "$AFTER_OVERWRITE"

# ============ 10. Clean up ============
log "10. Cleanup"
mc rm --force --recursive "local/$BUCKET/" >/dev/null 2>&1
mc rb "local/$BUCKET" >/dev/null 2>&1
GONE=$(mc ls local/ | grep -c "$BUCKET/" || true)
test_result "Bucket cleaned up" "0" "$GONE"

printf '\n==========================================\n'
printf '  Metadata/Tag tests:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
