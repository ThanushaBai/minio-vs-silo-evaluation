#!/bin/bash
# seed-versioned.sh — Populate MinIO with versioning, tags, metadata, and object-lock.
#
# Creates six feature-specific buckets:
#   demo-versioned    versioning enabled; 3 versions of one key + a delete marker
#   demo-tagged       objects with key-value tags
#   demo-metadata     objects with X-Amz-Meta-* custom metadata
#   demo-lock-gov     GOVERNANCE-mode retention (1 day)
#   demo-lock-comp    COMPLIANCE-mode retention (1 day)
#   demo-lock-legal   Legal Hold enabled on an object
#
# Usage: ./scripts/seed-versioned.sh

set -uo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
LOCAL_DIR="/data/testdata/local"

MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio)
[ -z "$MINIO_IP" ] && { echo "ERROR: MinIO container not found" >&2; exit 1; }

MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

mc() {
  docker run --rm --network "$MC_NET" \
    -v /data/testdata:/data/testdata:ro \
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

log() { printf '[seed-versioned] %s\n' "$*"; }

# ---------- 1. demo-versioned ----------
log "=== demo-versioned ==="
mc mb --ignore-existing local/demo-versioned >/dev/null
mc version enable local/demo-versioned >/dev/null
log "Versioning enabled"

echo "version-1-content" > "${LOCAL_DIR}/v1.txt"
echo "version-2-content-different" > "${LOCAL_DIR}/v2.txt"
echo "version-3-content-final" > "${LOCAL_DIR}/v3.txt"

for v in v1 v2 v3; do
  mc cp "${LOCAL_DIR}/${v}.txt" local/demo-versioned/versioned-key.txt >/dev/null
  sleep 1
done

mc rm local/demo-versioned/versioned-key.txt >/dev/null 2>&1 || true

log "Versions (including delete marker):"
mc ls --versions local/demo-versioned/

# ---------- 2. demo-tagged ----------
log ""
log "=== demo-tagged ==="
mc mb --ignore-existing local/demo-tagged >/dev/null
mc cp "${LOCAL_DIR}/small/obj-small-001.bin" local/demo-tagged/tagged-001.bin >/dev/null
mc cp "${LOCAL_DIR}/small/obj-small-002.bin" local/demo-tagged/tagged-002.bin >/dev/null
mc tag set "local/demo-tagged/tagged-001.bin" "env=test&team=devops&criticality=low" >/dev/null
mc tag set "local/demo-tagged/tagged-002.bin" "env=prod&team=platform&criticality=high" >/dev/null

log "Tags:"
for obj in tagged-001.bin tagged-002.bin; do
  echo "--- $obj ---"
  mc tag list "local/demo-tagged/$obj"
done

# ---------- 3. demo-metadata ----------
log ""
log "=== demo-metadata ==="
mc mb --ignore-existing local/demo-metadata >/dev/null

mc cp --attr "X-Amz-Meta-Owner=alice,X-Amz-Meta-Project=minio-eval" \
  "${LOCAL_DIR}/small/obj-small-003.bin" \
  local/demo-metadata/meta-001.bin >/dev/null

mc cp --attr "X-Amz-Meta-Owner=bob,X-Amz-Meta-Project=silo-eval,X-Amz-Meta-Stage=beta" \
  "${LOCAL_DIR}/small/obj-small-004.bin" \
  local/demo-metadata/meta-002.bin >/dev/null

log "Metadata:"
for obj in meta-001.bin meta-002.bin; do
  echo "--- $obj ---"
  mc stat "local/demo-metadata/$obj" | grep -A5 "Metadata"
done

# ---------- 4. demo-lock-gov ----------
log ""
log "=== demo-lock-gov (GOVERNANCE, 1d) ==="
mc mb --ignore-existing --with-lock local/demo-lock-gov >/dev/null
mc cp "${LOCAL_DIR}/small/obj-small-005.bin" local/demo-lock-gov/gov-object.bin >/dev/null
mc retention set --default governance 1d local/demo-lock-gov/ >/dev/null

log "Default retention:"
mc retention info --default local/demo-lock-gov/

# ---------- 5. demo-lock-comp ----------
log ""
log "=== demo-lock-comp (COMPLIANCE, 1d) ==="
mc mb --ignore-existing --with-lock local/demo-lock-comp >/dev/null
mc cp "${LOCAL_DIR}/small/obj-small-006.bin" local/demo-lock-comp/comp-object.bin >/dev/null
mc retention set --default compliance 1d local/demo-lock-comp/ >/dev/null

log "Default retention:"
mc retention info --default local/demo-lock-comp/

# ---------- 6. demo-lock-legal ----------
log ""
log "=== demo-lock-legal (Legal Hold) ==="
mc mb --ignore-existing --with-lock local/demo-lock-legal >/dev/null
mc cp "${LOCAL_DIR}/small/obj-small-007.bin" local/demo-lock-legal/legal-object.bin >/dev/null
mc legalhold set "local/demo-lock-legal/legal-object.bin" >/dev/null

log "Legal hold:"
mc legalhold info "local/demo-lock-legal/legal-object.bin"

# ---------- Summary ----------
log ""
log "=== Summary: all feature buckets ==="
mc ls local/ | grep -E "demo-versioned|demo-tagged|demo-metadata|demo-lock"

log ""
log "Versioned bucket objects (versions + delete markers):"
mc ls --versions local/demo-versioned/ | wc -l

log ""
log "Total buckets:"
mc ls local/ | wc -l

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
log ""
log "seed-versioned.sh complete."
