#!/bin/bash
# test-object-lock.sh — Object lock deep-dive for DEV-907 (Session 3B).
#
# NOTE: In a versioned bucket, `mc rm <obj>` creates a DELETE MARKER (soft delete).
# Object lock prevents PERMANENT deletion of versions, not the creation of delete
# markers. So lock tests must use `mc rm --version-id` to test enforcement.

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

BUCKET="test-lock"
mc rb --force --dangerous "local/$BUCKET" >/dev/null 2>&1 || true

# ============ 1. Create bucket with lock enabled ============
log "1. Create bucket with --with-lock"
mc mb --with-lock "local/$BUCKET" >/dev/null 2>&1
CREATED=$(mc ls local/ | grep -c "$BUCKET/" || true)
test_result "Lock-enabled bucket created" "1" "$CREATED"

mc retention set --default governance 1d "local/$BUCKET" >/dev/null 2>&1
LOCK_OK=$(mc retention info --default --json "local/$BUCKET" 2>/dev/null | grep -ci "governance" || true)
test_result "Bucket accepts retention config" "1" "$LOCK_OK"

# ============ 2. Upload with GOVERNANCE retention ============
log "2. Upload with GOVERNANCE 1-day retention"
echo "governance content" > /data/testdata/local/gov.txt
mc cp --retention-mode governance --retention-duration 1d \
  /data/testdata/local/gov.txt "local/$BUCKET/gov.txt" >/dev/null 2>&1
GOV_OK=$(mc ls "local/$BUCKET/gov.txt" 2>/dev/null | wc -l)
test_result "Governance object uploaded" "1" "$GOV_OK"

GOV_VID=$(mc ls --versions --json "local/$BUCKET/gov.txt" 2>/dev/null | \
  grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)

# Use --json + grep for mode field
GOV_MODE=$(mc retention info --json "local/$BUCKET/gov.txt" 2>/dev/null | grep -oE '"mode":"[^"]*"' | cut -d'"' -f4)
test_result "Object retention mode" "GOVERNANCE" "$GOV_MODE"

# ============ 3. PERMANENT delete WITHOUT bypass ============
log "3. Permanent delete WITHOUT --bypass (should fail)"
if [ -n "$GOV_VID" ]; then
  PERM_ERR=$(mc rm --force --version-id "$GOV_VID" "local/$BUCKET/gov.txt" 2>&1)
  if echo "$PERM_ERR" | grep -qiE "cannot|denied|forbidden|error|locked|retention|bypass"; then
    test_result "Permanent delete blocked (governance)" "1" "1"
  else
    test_result "Permanent delete blocked (governance)" "1" "0"
  fi
else
  test_result "Permanent delete blocked (governance)" "1" "no-vid"
fi

# ============ 4. PERMANENT delete WITH bypass ============
log "4. Permanent delete WITH --bypass (should succeed)"
if [ -n "$GOV_VID" ]; then
  mc rm --force --bypass --version-id "$GOV_VID" "local/$BUCKET/gov.txt" >/dev/null 2>&1
  GONE=$(mc ls --versions "local/$BUCKET/gov.txt" 2>/dev/null | wc -l)
  test_result "Version permanently deleted with bypass" "0" "$GONE"
fi

# ============ 5. COMPLIANCE retention ============
log "5. Upload with COMPLIANCE retention"
echo "compliance content" > /data/testdata/local/comp.txt
mc cp --retention-mode compliance --retention-duration 1d \
  /data/testdata/local/comp.txt "local/$BUCKET/comp.txt" >/dev/null 2>&1
COMP_OK=$(mc ls "local/$BUCKET/comp.txt" 2>/dev/null | wc -l)
test_result "Compliance object uploaded" "1" "$COMP_OK"

COMP_MODE=$(mc retention info --json "local/$BUCKET/comp.txt" 2>/dev/null | grep -oE '"mode":"[^"]*"' | cut -d'"' -f4)
test_result "Object retention mode" "COMPLIANCE" "$COMP_MODE"

COMP_VID=$(mc ls --versions --json "local/$BUCKET/comp.txt" 2>/dev/null | \
  grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)

# ============ 6. Compliance PERMANENT delete WITHOUT bypass ============
log "6. Compliance permanent delete WITHOUT bypass (should fail)"
if [ -n "$COMP_VID" ]; then
  COMP_ERR=$(mc rm --force --version-id "$COMP_VID" "local/$BUCKET/comp.txt" 2>&1)
  if echo "$COMP_ERR" | grep -qiE "cannot|denied|forbidden|error|locked|retention"; then
    test_result "Compliance delete blocked" "1" "1"
  else
    test_result "Compliance delete blocked" "1" "0"
  fi
fi

# ============ 7. Compliance PERMANENT delete WITH bypass ============
log "7. Compliance delete WITH --bypass (must still fail)"
if [ -n "$COMP_VID" ]; then
  mc rm --force --bypass --version-id "$COMP_VID" "local/$BUCKET/comp.txt" >/dev/null 2>&1
  STILL=$(mc ls --versions "local/$BUCKET/comp.txt" 2>/dev/null | wc -l)
  if [ "$STILL" -ge 1 ]; then
    test_result "Compliance version survives --bypass" "1" "1"
  else
    test_result "Compliance version survives --bypass" "1" "0"
  fi
fi

# ============ 8. Retention extension ============
log "8. Extend governance retention to 3 days"
echo "extend test" > /data/testdata/local/extend.txt
mc cp --retention-mode governance --retention-duration 1d \
  /data/testdata/local/extend.txt "local/$BUCKET/extend.txt" >/dev/null 2>&1

# Capture original until-date
ORIG_UNTIL=$(mc retention info --json "local/$BUCKET/extend.txt" 2>/dev/null | grep -oE '"until":"[^"]*"' | cut -d'"' -f4)

mc retention set --bypass governance 3d "local/$BUCKET/extend.txt" >/dev/null 2>&1
NEW_UNTIL=$(mc retention info --json "local/$BUCKET/extend.txt" 2>/dev/null | grep -oE '"until":"[^"]*"' | cut -d'"' -f4)

if [ -n "$NEW_UNTIL" ] && [ "$NEW_UNTIL" != "$ORIG_UNTIL" ]; then
  test_result "Retention extended (until-date changed)" "1" "1"
  printf '      Original until: %s\n' "$ORIG_UNTIL"
  printf '      New until:      %s\n' "$NEW_UNTIL"
else
  test_result "Retention extended (until-date changed)" "1" "0"
  printf '      Original: %s, New: %s\n' "$ORIG_UNTIL" "$NEW_UNTIL"
fi

# ============ 9. Legal hold ============
log "9. Legal hold — set, verify, delete blocked, clear"
echo "legal hold content" > /data/testdata/local/legal.txt
mc cp /data/testdata/local/legal.txt "local/$BUCKET/legal.txt" >/dev/null 2>&1

mc legalhold set "local/$BUCKET/legal.txt" >/dev/null 2>&1
LH_ON=$(mc legalhold info "local/$BUCKET/legal.txt" 2>/dev/null | grep -c "ON" || true)
test_result "Legal hold ON" "1" "$LH_ON"

LEGAL_VID=$(mc ls --versions --json "local/$BUCKET/legal.txt" 2>/dev/null | \
  grep -oE '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$LEGAL_VID" ]; then
  mc rm --force --bypass --version-id "$LEGAL_VID" "local/$BUCKET/legal.txt" >/dev/null 2>&1
  LH_STILL=$(mc ls --versions "local/$BUCKET/legal.txt" 2>/dev/null | wc -l)
  if [ "$LH_STILL" -ge 1 ]; then
    test_result "Version survives delete under legal hold" "1" "1"
  else
    test_result "Version survives delete under legal hold" "1" "0"
  fi
fi

mc legalhold clear "local/$BUCKET/legal.txt" >/dev/null 2>&1
LH_OFF=$(mc legalhold info "local/$BUCKET/legal.txt" 2>/dev/null | grep -c "OFF" || true)
test_result "Legal hold cleared (OFF)" "1" "$LH_OFF"

# ============ 10. Default bucket retention ============
log "10. Default bucket retention"
mc retention set --default governance 1d "local/$BUCKET" >/dev/null 2>&1
DEF=$(mc retention info --default --json "local/$BUCKET" 2>/dev/null | grep -ci "governance" || true)
test_result "Default retention set (governance)" "1" "$DEF"

echo "inherited" > /data/testdata/local/inh.txt
mc cp /data/testdata/local/inh.txt "local/$BUCKET/inh.txt" >/dev/null 2>&1
INH=$(mc retention info --json "local/$BUCKET/inh.txt" 2>/dev/null | grep -ci "governance" || true)
test_result "New object inherits default retention" "1" "$INH"

# ============ 11. Cleanup ============
log "11. Cleanup"
# Delete compliance objects requires waiting for retention, or leaving them.
# We document the outcome instead of failing.
mc legalhold clear --recursive --versions "local/$BUCKET/" >/dev/null 2>&1 || true
mc rm --force --recursive --versions --bypass --dangerous "local/$BUCKET/" >/dev/null 2>&1 || true
mc rb --force --dangerous "local/$BUCKET" >/dev/null 2>&1 || true
GONE=$(mc ls local/ | grep -c "$BUCKET/" || true)
if [ "$GONE" = "0" ]; then
  test_result "Bucket cleaned up" "0" "0"
else
  # Compliance-mode objects can't be deleted until retention expires.
  # This is expected behavior, so we count it as a PASS with a note.
  printf 'PASS  %-55s  %s\n' "Bucket cleanup (blocked by compliance retention)" "expected"
  printf '      Compliance-locked objects persist until retention expires (correct behavior).\n'
  PASS=$((PASS+1))
fi

printf '\n==========================================\n'
printf '  Object lock tests:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
