#!/bin/bash
# manifest-compare.sh — Compare two manifest CSVs and report differences.
#
# Usage: ./scripts/manifest-compare.sh <manifest-a.csv> <manifest-b.csv>
#
# Exit codes:
#   0 = manifests identical
#   1 = differences found
#   2 = invalid arguments or missing files

set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <manifest-a.csv> <manifest-b.csv>" >&2
  exit 2
fi

A="$1"
B="$2"

for f in "$A" "$B"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: file not found: $f" >&2
    exit 2
  fi
done

OUT_DIR="manifests"
mkdir -p "$OUT_DIR"
REPORT="${OUT_DIR}/compare-report-$(date +%Y%m%dT%H%M%S).txt"

# Run comparison, capture output and exit code
COMPARE_OUTPUT=$(python3 - "$A" "$B" << 'PYEOF'
import sys, csv

A_path, B_path = sys.argv[1], sys.argv[2]

def normalize_vid(v):
    if v is None:
        return ''
    v = str(v).strip()
    if v.lower() in ('null', 'none', ''):
        return ''
    return v

def load(path):
    rows = {}
    with open(path, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            vid = normalize_vid(row.get('version_id', ''))
            k = (row['bucket'], row['key'], vid)
            rows[k] = row
    return rows

A = load(A_path)
B = load(B_path)

A_keys = set(A.keys())
B_keys = set(B.keys())

only_in_A = sorted(A_keys - B_keys)
only_in_B = sorted(B_keys - A_keys)
in_both = sorted(A_keys & B_keys)

altered = []
for k in in_both:
    ra, rb = A[k], B[k]
    if ra['size'] != rb['size'] or ra['etag'] != rb['etag']:
        altered.append((k, ra, rb))

print(f"--- Summary ---")
print(f"Rows in A:            {len(A)}")
print(f"Rows in B:            {len(B)}")
print(f"Keys in A only:       {len(only_in_A)}")
print(f"Keys in B only:       {len(only_in_B)}")
print(f"Keys in both:         {len(in_both)}")
print(f"Altered (size/etag):  {len(altered)}")
print("")

total_diffs = len(only_in_A) + len(only_in_B) + len(altered)

if total_diffs == 0:
    print("RESULT: PASS - manifests are identical")
    sys.exit(0)

print("RESULT: FAIL - differences detected")
print("")

if only_in_A:
    print(f"--- MISSING: in A but not B ({len(only_in_A)}) ---")
    for k in only_in_A[:50]:
        bucket, key, vid = k
        print(f"  {bucket}/{key}  version={vid or '-'}")
    if len(only_in_A) > 50:
        print(f"  ... and {len(only_in_A) - 50} more")
    print("")

if only_in_B:
    print(f"--- EXTRA: in B but not A ({len(only_in_B)}) ---")
    for k in only_in_B[:50]:
        bucket, key, vid = k
        print(f"  {bucket}/{key}  version={vid or '-'}")
    if len(only_in_B) > 50:
        print(f"  ... and {len(only_in_B) - 50} more")
    print("")

if altered:
    print(f"--- ALTERED: size or etag differs ({len(altered)}) ---")
    for k, ra, rb in altered[:50]:
        bucket, key, vid = k
        print(f"  {bucket}/{key}  version={vid or '-'}")
        print(f"    A: size={ra['size']}  etag={ra['etag']}")
        print(f"    B: size={rb['size']}  etag={rb['etag']}")
    if len(altered) > 50:
        print(f"  ... and {len(altered) - 50} more")
    print("")

sys.exit(1)
PYEOF
)

RESULT=$?

# Print report to stdout AND save to file
{
  echo "=== Manifest Comparison Report ==="
  echo "Date:       $(date -Iseconds)"
  echo "Manifest A: $A"
  echo "Manifest B: $B"
  echo "Report:     $REPORT"
  echo ""
  echo "$COMPARE_OUTPUT"
  echo ""
  echo "Exit code: $RESULT"
} | tee "$REPORT"

echo ""
echo "Report saved to: $REPORT"
exit "$RESULT"
