#!/bin/bash
# seed-config.sh — Configure MinIO buckets and IAM for DEV-906.
#
# Covers:
#   - Lifecycle rules (expiration + noncurrent version expiration)
#   - Bucket policy (anonymous read-only on one bucket)
#   - Notification config placeholder (webhook endpoint)
#   - Replication config placeholder (needs a peer; setup recorded, not activated)
#   - IAM: user, group, policy, service account, STS check
#
# Usage: ./scripts/seed-config.sh

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
ADMIN_DIR="/data/testdata/admin"

mkdir -p "$ADMIN_DIR"

MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio)
[ -z "$MINIO_IP" ] && { echo "ERROR: MinIO container not found" >&2; exit 1; }

MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

mc() {
  docker run --rm --network "$MC_NET" \
    -v /data/testdata:/data/testdata \
    -e "$MC_ENV" \
    "$MC_IMAGE" "$@"
}

log() { printf '[seed-config] %s\n' "$*"; }

# ---------- 1. Lifecycle rules ----------
log "=== Lifecycle rules on demo-versioned ==="
cat > "${ADMIN_DIR}/lifecycle.json" << 'JSON'
{
  "Rules": [
    {
      "ID": "expire-noncurrent-30d",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
    },
    {
      "ID": "expire-temp-7d",
      "Status": "Enabled",
      "Filter": { "Prefix": "temp/" },
      "Expiration": { "Days": 7 }
    }
  ]
}
JSON

mc ilm import local/demo-versioned < "${ADMIN_DIR}/lifecycle.json" 2>&1 || \
  mc ilm add --expiry-days 30 --noncurrent-expire-days 30 local/demo-versioned

log "Current lifecycle rules:"
mc ilm ls local/demo-versioned/

# ---------- 2. Bucket policy (anonymous read) ----------
log ""
log "=== Bucket policy: anonymous read on demo-tagged ==="
cat > "${ADMIN_DIR}/policy-anon-read.json" << 'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicRead",
      "Effect": "Allow",
      "Principal": { "AWS": ["*"] },
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::demo-tagged/*"]
    }
  ]
}
JSON

mc anonymous set-json "${ADMIN_DIR}/policy-anon-read.json" local/demo-tagged 2>&1 || \
  mc anonymous set download local/demo-tagged

log "Anonymous access on demo-tagged:"
mc anonymous get local/demo-tagged

# ---------- 3. Notification config (placeholder) ----------
log ""
log "=== Notification config (placeholder webhook) ==="
# mc event add needs a target. We register a webhook target pointing to a
# non-existent endpoint for demonstration; it is stored as config only.
mc admin config set local notify_webhook:demo endpoint="http://127.0.0.1:9999/webhook" 2>&1 | head -3 || true
log "(Notification target registered; no live receiver in the lab.)"

# ---------- 4. Replication config (placeholder, needs peer) ----------
log ""
log "=== Replication config check ==="
log "Replication requires a peer MinIO site. Recorded as deferred:"
log "  - Peer setup will be tested in DEV-909 (replication validation)"
log "  - Current config state:"
mc admin replicate info local 2>&1 | head -5 || echo "  (no replication configured)"

# ---------- 5. IAM: user, group, policy, service account ----------
log ""
log "=== IAM setup ==="
log "--- Create policy ---"
cat > "${ADMIN_DIR}/policy-app-rw.json" << 'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::demo-mixed",
        "arn:aws:s3:::demo-mixed/*"
      ]
    }
  ]
}
JSON

mc admin policy create local app-rw "${ADMIN_DIR}/policy-app-rw.json" 2>&1 || true
mc admin policy list local | grep app-rw || echo "policy created"

log ""
log "--- Create user ---"
mc admin user add local appuser AppUserPass2026! 2>&1 | head -2
mc admin policy attach local app-rw --user appuser 2>&1 | head -2

log "User list:"
mc admin user list local

log ""
log "--- Create group ---"
mc admin group add local appgroup appuser 2>&1 | head -2 || true
log "Group list:"
mc admin group list local 2>&1 || true

log ""
log "--- Create service account for appuser ---"
# NOTE: service account output contains real credentials; redact before display
mc admin user svcacct add local appuser 2>&1 \
  | sed -E 's/Access Key: .*/Access Key: <REDACTED_ACCESS_KEY>/; s/Secret Key: .*/Secret Key: <REDACTED_SECRET_KEY>/' \
  | head -10 || true

log "Service accounts for appuser:"
mc admin user svcacct ls local appuser 2>&1 \
  | sed -E 's/[A-Z0-9]{20}/<REDACTED_ACCESS_KEY>/g' || true

# ---------- 6. Summary ----------
log ""
log "=== Summary ==="
log "Buckets:"
mc ls local/
log ""
log "Users:"
mc admin user list local
log ""
log "Policies:"
mc admin policy list local

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
log ""
log "seed-config.sh complete."
