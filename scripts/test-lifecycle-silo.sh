#!/bin/bash
# test-lifecycle.sh — Lifecycle rules for DEV-907 (Session 4A).

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
  printf 'N/A   %-55s  %s\n' "$1" "$2"
  NA=$((NA+1))
}

log() { printf '\n--- %s ---\n' "$*"; }

# Helper: count rules in the JSON output (single-line JSON with Rules array)
count_rules() {
  mc ilm ls --json "local/$1" 2>/dev/null | grep -oE '"ID":"[^"]*"' | wc -l
}

BUCKET="test-lifecycle"
mc rb --force --dangerous "local/$BUCKET" >/dev/null 2>&1 || true
mc mb "local/$BUCKET" >/dev/null 2>&1
mc version enable "local/$BUCKET" >/dev/null 2>&1

# ============ 1. Current-version expiry ============
log "1. Current-version expiry rule (30d)"
mc ilm rule add --expire-days 30 "local/$BUCKET" >/dev/null 2>&1
N=$(count_rules "$BUCKET")
test_result "Expiry rule registered" "1" "$N"

# ============ 2. Rule has 30-day expiry ============
log "2. Rule content = 30 days"
HAS_30=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -c '"Days":30' || true)
test_result "Rule has Days:30" "1" "$HAS_30"

# ============ 3. Noncurrent version expiry ============
log "3. Noncurrent version expiry"
mc ilm rule add --noncurrent-expire-days 7 "local/$BUCKET" >/dev/null 2>&1
NONCUR=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -c '"NoncurrentVersionExpiration"' || true)
test_result "Noncurrent rule registered" "1" "$NONCUR"

# ============ 4. Delete-marker expiry ============
log "4. Delete-marker cleanup rule"
mc ilm rule add --expire-delete-marker "local/$BUCKET" >/dev/null 2>&1
DM_RULE=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -c '"ExpiredObjectDeleteMarker":true\|"ExpireDeleteMarker":true\|DeleteMarker' || true)
if [ "$DM_RULE" -ge 1 ]; then
  test_result "Delete-marker rule registered" "1" "1"
else
  # Check via rule count
  AFTER_DM=$(count_rules "$BUCKET")
  if [ "$AFTER_DM" -ge 3 ]; then
    test_result "Delete-marker rule registered" "1" "1"
  else
    test_result "Delete-marker rule registered" "1" "0"
  fi
fi

# ============ 5. Prefix-scoped rule ============
log "5. Prefix-scoped rule"
mc ilm rule add --expire-days 5 --prefix "temp/" "local/$BUCKET" >/dev/null 2>&1
PREFIX_RULE=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -c '"Prefix":"temp/"' || true)
test_result "Prefix rule registered" "1" "$PREFIX_RULE"

# ============ 6. List all rules ============
log "6. Total rules count"
TOTAL=$(count_rules "$BUCKET")
test_min "Multiple rules registered" 3 "$TOTAL"
echo "  Rules:"
mc ilm ls "local/$BUCKET" 2>&1 | head -20 | sed 's/^/    /'

# ============ 7. Remove specific rule ============
log "7. Remove a rule by ID"
RULE_ID=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -oE '"ID":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$RULE_ID" ]; then
  BEFORE=$(count_rules "$BUCKET")
  mc ilm rule rm --id "$RULE_ID" "local/$BUCKET" >/dev/null 2>&1
  AFTER=$(count_rules "$BUCKET")
  EXPECTED=$((BEFORE - 1))
  test_result "Rule removed by ID" "$EXPECTED" "$AFTER"
else
  test_result "Rule removed by ID" "found-id" "no-id"
fi

# ============ 8. Transition rule ============
log "8. Transition rule (needs remote tier)"
TIER_LS=$(mc ilm tier ls local 2>/dev/null | grep -vE "^$|No|Tier" | wc -l)
TIER_LS=$(echo "$TIER_LS" | head -1 | tr -d '[:space:]')
[ -z "$TIER_LS" ] && TIER_LS=0
if [ "$TIER_LS" -ge 1 ]; then
  mc ilm rule add --transition-days 1 --transition-tier "standard" "local/$BUCKET" >/dev/null 2>&1
  TRANS=$(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -c '"Transition"' || true)
  test_result "Transition rule registered" "1" "$TRANS"
else
  test_na "Transition to tier" "no remote tier configured (out of lab scope)"
fi

# ============ 9. Rule persistence ============
log "9. Rule persistence"
PERSIST=$(count_rules "$BUCKET")
if [ "$PERSIST" -ge 1 ]; then
  test_result "Rules persist after ops" "1" "1"
else
  test_result "Rules persist after ops" "1" "0"
fi

# ============ 10. Cleanup ============
log "10. Cleanup"
# Remove all rules by ID
for RID in $(mc ilm ls --json "local/$BUCKET" 2>/dev/null | grep -oE '"ID":"[^"]*"' | cut -d'"' -f4); do
  mc ilm rule rm --id "$RID" "local/$BUCKET" >/dev/null 2>&1 || true
done
mc rb --force --dangerous "local/$BUCKET" >/dev/null 2>&1 || true
GONE=$(mc ls local/ | grep -c "$BUCKET/" || true)
test_result "Bucket cleaned up" "0" "$GONE"

printf '\n==========================================\n'
printf '  Lifecycle tests:  PASS=%d  FAIL=%d  N/A=%d\n' "$PASS" "$FAIL" "$NA"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
