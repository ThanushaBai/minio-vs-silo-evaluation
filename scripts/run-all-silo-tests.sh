#!/bin/bash
# run-all-silo-tests.sh — Run all MinIO test scripts against Silo (DEV-911).
# Creates *-silo.sh variants and runs them, saving evidence to docs/07-*/evidence/.

set -uo pipefail
cd "$(dirname "$0")/.."

EVIDENCE_DIR="docs/07-silo-functional-validation/evidence"
mkdir -p "$EVIDENCE_DIR"

TESTS=(
  "test-metadata-tags"
  "test-access-control"
  "test-encryption"
  "test-observability"
  "test-versioning"
  "test-object-lock"
  "test-lifecycle"
  "test-sdk-compat"
)

log() { printf '\n\n########## %s ##########\n' "$*"; }

for base in "${TESTS[@]}"; do
  src="scripts/${base}.sh"
  dst="scripts/${base}-silo.sh"

  if [ ! -f "$src" ]; then
    log "SKIP: $src not found"
    continue
  fi

  log "Creating Silo variant of $base"
  # Copy and substitute container endpoint
  sed 's/minio:9000/silo:9000/g; s/minio-target:9000/silo-target:9000/g' "$src" > "$dst"
  chmod +x "$dst"

  log "Running $base against Silo"
  ./"$dst" 2>&1 | tee "$EVIDENCE_DIR/${base}-silo-output.txt"
done

log "All Silo test runs complete"
ls -la "$EVIDENCE_DIR/"
