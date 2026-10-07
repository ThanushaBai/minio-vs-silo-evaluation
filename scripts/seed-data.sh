#!/bin/bash
# seed-data.sh — Generate the local synthetic dataset for DEV-906.
# Deterministic: same file name + seed => same bytes => same SHA256.

set -uo pipefail

SEED_ROOT="${SEED_ROOT:-/data/testdata}"
LOCAL_DIR="${SEED_ROOT}/local"
SEED=20261006

log() { printf '[seed-data] %s\n' "$*"; }
fail() { printf '[seed-data] ERROR: %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || fail "openssl is required"

log "Preparing directories under ${LOCAL_DIR}"
mkdir -p "${LOCAL_DIR}/small"
mkdir -p "${LOCAL_DIR}/medium"
mkdir -p "${LOCAL_DIR}/large"
mkdir -p "${LOCAL_DIR}/nested/level1/level2/level3"
mkdir -p "${LOCAL_DIR}/flat"

# gen_file <path> <size_kb> <label>
gen_file() {
  local path="$1" size_kb="$2" label="$3"
  local key
  key=$(printf '%s-%s' "$label" "$SEED" | sha256sum | awk '{print $1}')

  # Write size_kb*1024 bytes: read from /dev/zero, encrypt with fixed key.
  # We let openssl write everything, then truncate using `truncate -s` (no SIGPIPE).
  local bytes=$(( size_kb * 1024 ))
  local blocks=$(( (bytes + 1048575) / 1048576 ))
  [ "$blocks" -lt 1 ] && blocks=1

  dd if=/dev/zero bs=1M count="$blocks" 2>/dev/null \
    | openssl enc -aes-256-ctr -K "$key" -iv 0 -nosalt 2>/dev/null \
    > "$path"
  truncate -s "$bytes" "$path"
}

log "Generating 100 small objects (10 KB each)"
for i in $(seq -w 1 100); do
  gen_file "${LOCAL_DIR}/small/obj-small-${i}.bin" 10 "small-${i}"
done

log "Generating 20 medium objects (1 MB each)"
for i in $(seq -w 1 20); do
  gen_file "${LOCAL_DIR}/medium/obj-medium-${i}.bin" 1024 "medium-${i}"
done

log "Generating 1 large object (200 MB)"
gen_file "${LOCAL_DIR}/large/obj-large-001.bin" 204800 "large-001"

log "Generating 15 nested objects (5 KB each) across 3 levels"
for i in $(seq -w 1 5); do
  gen_file "${LOCAL_DIR}/nested/level1/file-${i}.bin" 5 "nested-l1-${i}"
done
for i in $(seq -w 1 5); do
  gen_file "${LOCAL_DIR}/nested/level1/level2/file-${i}.bin" 5 "nested-l2-${i}"
done
for i in $(seq -w 1 5); do
  gen_file "${LOCAL_DIR}/nested/level1/level2/level3/file-${i}.bin" 5 "nested-l3-${i}"
done

log "Generating 200 flat objects (2 KB each)"
for i in $(seq -w 1 200); do
  gen_file "${LOCAL_DIR}/flat/obj-flat-${i}.bin" 2 "flat-${i}"
done

log ""
log "=== Summary ==="
for d in small medium large nested flat; do
  count=$(find "${LOCAL_DIR}/${d}" -type f | wc -l)
  size=$(du -sh "${LOCAL_DIR}/${d}" | awk '{print $1}')
  printf '  %-10s  %4d files  %s\n' "$d" "$count" "$size"
done
total_files=$(find "${LOCAL_DIR}" -type f | wc -l)
total_size=$(du -sh "${LOCAL_DIR}" | awk '{print $1}')
log ""
log "TOTAL: ${total_files} files, ${total_size}"
log "Dataset ready at: ${LOCAL_DIR}"
