#!/bin/bash
# seed-upload.sh — Create buckets and upload the synthetic dataset to MinIO.
#
# Buckets:
#   demo-small   100 x 10 KB
#   demo-medium  20  x 1 MB
#   demo-large   1   x 200 MB
#   demo-nested  deep prefix layout (3 levels)
#   demo-flat    200 x 2 KB (large object count)
#   demo-mixed   sample from each category
#
# Usage: ./scripts/seed-upload.sh

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

# Resolve the MinIO container IP for mc to reach it
MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio 2>/dev/null)
[ -z "$MINIO_IP" ] && { echo "ERROR: cannot find MinIO container" >&2; exit 1; }

MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

# Run mc on the same docker network as MinIO
mc() {
  docker run --rm --network "$MC_NET" \
    -v /data/testdata:/data/testdata:ro \
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

log() { printf '[seed-upload] %s\n' "$*"; }

# --- Create buckets ---
log "Creating buckets"
for b in demo-small demo-medium demo-large demo-nested demo-flat demo-mixed; do
  mc mb --ignore-existing "local/$b" > /dev/null
  echo "  created: $b"
done

# --- Upload contents ---
log "Uploading demo-small (100 files)"
mc cp --recursive "${LOCAL_DIR}/small/" local/demo-small/ > /dev/null

log "Uploading demo-medium (20 files)"
mc cp --recursive "${LOCAL_DIR}/medium/" local/demo-medium/ > /dev/null

log "Uploading demo-large (1 file)"
mc cp "${LOCAL_DIR}/large/obj-large-001.bin" local/demo-large/ > /dev/null

log "Uploading demo-nested (deep prefix layout)"
mc cp --recursive "${LOCAL_DIR}/nested/" local/demo-nested/ > /dev/null

log "Uploading demo-flat (200 files)"
mc cp --recursive "${LOCAL_DIR}/flat/" local/demo-flat/ > /dev/null

log "Uploading demo-mixed (2 files from each category)"
mc cp "${LOCAL_DIR}/small/obj-small-001.bin" local/demo-mixed/small-001.bin > /dev/null
mc cp "${LOCAL_DIR}/small/obj-small-002.bin" local/demo-mixed/small-002.bin > /dev/null
mc cp "${LOCAL_DIR}/medium/obj-medium-01.bin" local/demo-mixed/medium-01.bin > /dev/null
mc cp "${LOCAL_DIR}/medium/obj-medium-02.bin" local/demo-mixed/medium-02.bin > /dev/null
mc cp "${LOCAL_DIR}/nested/level1/file-1.bin" local/demo-mixed/nested-file-01.bin > /dev/null
mc cp "${LOCAL_DIR}/nested/level1/level2/file-1.bin" local/demo-mixed/nested-file-02.bin > /dev/null
mc cp "${LOCAL_DIR}/flat/obj-flat-001.bin" local/demo-mixed/flat-001.bin > /dev/null
mc cp "${LOCAL_DIR}/flat/obj-flat-002.bin" local/demo-mixed/flat-002.bin > /dev/null

# --- Verify ---
log ""
log "=== Bucket summary ==="
mc ls local/
log ""
log "=== Per-bucket object counts ==="
for b in demo-small demo-medium demo-large demo-nested demo-flat demo-mixed; do
  count=$(mc ls --recursive "local/$b/" 2>/dev/null | wc -l)
  printf '  %-14s  %4d objects\n' "$b" "$count"
done

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
log ""
log "Upload complete."
