#!/bin/bash
# manifest.sh — Export a manifest of all objects across all buckets in MinIO.
#
# Output: CSV with columns:
#   bucket,key,version_id,version_ordinal,last_modified,is_delete_marker,
#   size,etag,storage_class,metadata,tags,retention_mode,retention_until,legal_hold
#
# Usage: ./scripts/manifest.sh [output.csv]
# Default output: manifests/minio-manifest-<timestamp>.csv

set -uo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi
set -a; . ./.env; set +a

MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"

OUT_FILE="${1:-manifests/minio-manifest-$(date +%Y%m%dT%H%M%S).csv}"
mkdir -p "$(dirname "$OUT_FILE")"

MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio)
[ -z "$MINIO_IP" ] && { echo "ERROR: MinIO container not found" >&2; exit 1; }

MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

# Run mc on the network
mc() {
  docker run --rm --network "$MC_NET" \
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

log() { printf '[manifest] %s\n' "$*" >&2; }

# CSV header
echo "bucket,key,version_id,version_ordinal,last_modified,is_delete_marker,size,etag,storage_class,metadata,tags,retention_mode,retention_until,legal_hold" > "$OUT_FILE"

# Get list of buckets (skip system buckets)
BUCKETS=$(mc ls local/ | awk '{print $NF}' | sed 's|/$||' | grep -v "^\." || true)

log "Buckets found: $(echo "$BUCKETS" | wc -w)"
log "Writing to: $OUT_FILE"

TOTAL=0

for bucket in $BUCKETS; do
  log "Processing bucket: $bucket"

  # List all versions as JSON lines (one per object version)
  # Fall back to non-versioned listing if the bucket doesn't have versioning
  JSON=$(mc ls --versions --json "local/$bucket/" 2>/dev/null || true)

  if [ -z "$JSON" ]; then
    # Try non-versioned
    JSON=$(mc ls --json "local/$bucket/" 2>/dev/null || true)
  fi

  # Parse each JSON line
  echo "$JSON" | while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Parse fields using python (available on host) for robustness
    python3 - "$line" "$bucket" >> "$OUT_FILE" << 'PYEOF'
import sys, json, csv, io

try:
    obj = json.loads(sys.argv[1])
    bucket = sys.argv[2]
except Exception:
    sys.exit(0)

key = obj.get("key", "")
version_id = obj.get("versionId", "") or ""
version_ordinal = obj.get("versionOrdinal", 0)
last_modified = obj.get("lastModified", "") or ""
is_dm = "true" if obj.get("isDeleteMarker", False) else ""
size = obj.get("size", 0)
etag = obj.get("etag", "") or ""
storage_class = obj.get("storageClass", "") or ""

# Metadata may contain user-defined keys (mc ls --json doesn't include these;
# placeholder for future enhancement)
metadata = obj.get("metadata", {}) or {}
meta_str = ";".join(f"{k}={v}" for k, v in sorted(metadata.items()) if k.lower().startswith("x-amz-meta"))

# Tags, retention, legal hold: not in list output
tags = ""
retention_mode = ""
retention_until = ""
legal_hold = ""

# is_latest is inferred by the caller via versionOrdinal (highest = latest)
out = io.StringIO()
w = csv.writer(out, quoting=csv.QUOTE_MINIMAL)
w.writerow([bucket, key, version_id, version_ordinal, last_modified, is_dm, size, etag, storage_class, meta_str, tags, retention_mode, retention_until, legal_hold])
print(out.getvalue().rstrip())
PYEOF

    TOTAL=$((TOTAL + 1))
  done
done

log "Manifest complete: $(wc -l < "$OUT_FILE") lines (including header)"
echo "$OUT_FILE"
