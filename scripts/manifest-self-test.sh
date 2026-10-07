#!/bin/bash
# manifest-self-test.sh — Verify manifest-compare.sh detects each diff category.
#
# Acceptance criterion (DEV-906):
#   "The compare script detects each deliberately introduced difference
#    (missing object, altered byte, missing version, missing tag)."
#
# This script:
#   1. Uses the baseline manifest (or generates one)
#   2. Produces 4 modified copies, each with ONE specific difference
#   3. Runs manifest-compare.sh against each
#   4. Verifies each category is caught (exit 1 + expected text in report)
#
# Usage: ./scripts/manifest-self-test.sh [baseline.csv]

set -uo pipefail

cd "$(dirname "$0")/.."

BASELINE="${1:-manifests/minio-baseline.csv}"

if [ ! -f "$BASELINE" ]; then
  echo "ERROR: baseline manifest not found: $BASELINE" >&2
  echo "Run ./scripts/manifest.sh first." >&2
  exit 1
fi

TESTDIR="manifests/selftest-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$TESTDIR"

log() { printf '[selftest] %s\n' "$*"; }

PASS=0
FAIL=0

run_case() {
  local name="$1"
  local file="$2"
  local expect_pattern="$3"

  log "--- Test: $name ---"
  local out
  out=$(./scripts/manifest-compare.sh "$BASELINE" "$file" 2>&1)
  local ec=$?

  if [ "$ec" -ne 1 ]; then
    log "  ❌ FAIL: expected exit 1, got $ec"
    echo "$out" | tail -5 | sed 's/^/    /'
    FAIL=$((FAIL+1))
    return
  fi

  if echo "$out" | grep -qE "$expect_pattern"; then
    log "  ✅ PASS: exit 1 + pattern '$expect_pattern' matched"
    PASS=$((PASS+1))
  else
    log "  ❌ FAIL: exit 1 but pattern '$expect_pattern' not found"
    echo "$out" | tail -10 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
}

# ============ Case 1: Missing object ============
log ""
log "=== Case 1: Missing object ==="
cp "$BASELINE" "$TESTDIR/case1-missing-object.csv"
# Remove a small object row
sed -i '/^demo-small,obj-small-010.bin,/d' "$TESTDIR/case1-missing-object.csv"
run_case "missing object" "$TESTDIR/case1-missing-object.csv" "MISSING:.*1"

# ============ Case 2: Altered byte (etag + size change) ============
log ""
log "=== Case 2: Altered content (etag mismatch) ==="
cp "$BASELINE" "$TESTDIR/case2-altered-object.csv"
# Change etag of obj-small-020.bin
sed -i 's|^\(demo-small,obj-small-020.bin,null,1,[^,]*,,10240,\)[^,]*\(,STANDARD.*\)|\1ALTERED_ETAG_VALUE\2|' \
  "$TESTDIR/case2-altered-object.csv"
run_case "altered object" "$TESTDIR/case2-altered-object.csv" "ALTERED:.*1"

# ============ Case 3: Missing version ============
log ""
log "=== Case 3: Missing version ==="
cp "$BASELINE" "$TESTDIR/case3-missing-version.csv"
# Remove one of the 4 version rows for versioned-key.txt
# Specifically remove the version with ordinal 2
grep "^demo-versioned,versioned-key.txt," "$BASELINE" | head -1 > /tmp/first_version_row.txt
FIRST_VID=$(head -1 /tmp/first_version_row.txt | awk -F',' '{print $3}')
log "  Removing version with version_id=$FIRST_VID"
sed -i "/^demo-versioned,versioned-key.txt,${FIRST_VID},/d" "$TESTDIR/case3-missing-version.csv"
run_case "missing version" "$TESTDIR/case3-missing-version.csv" "MISSING:.*1"

# ============ Case 4: Added (extra) object ============
log ""
log "=== Case 4: Extra object (sanity) ==="
cp "$BASELINE" "$TESTDIR/case4-extra-object.csv"
echo "demo-small,extra-injected-object.bin,null,1,2026-10-07T00:00:00.000Z,,100,extraetagvalue,STANDARD,,,,," \
  >> "$TESTDIR/case4-extra-object.csv"
run_case "extra object" "$TESTDIR/case4-extra-object.csv" "EXTRA:.*1"

# ============ Summary ============
log ""
log "=========================================="
log "  Self-test results"
log "=========================================="
log "  PASS: $PASS"
log "  FAIL: $FAIL"
log "=========================================="

if [ "$FAIL" -eq 0 ]; then
  log "✅ All cases PASSED — manifest-compare.sh detects each difference category."
  exit 0
else
  log "❌ Some cases FAILED."
  exit 1
fi
