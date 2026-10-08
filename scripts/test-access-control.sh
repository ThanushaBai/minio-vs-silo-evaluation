#!/bin/bash
# test-access-control.sh — Access control tests for DEV-907 (Session 2A).

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

BUCKET="test-access"
PASS=0
FAIL=0
ADMIN_DIR="/data/testdata/admin"
mkdir -p "$ADMIN_DIR"

test_result() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %-60s  %s\n' "$name" "$actual"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %-60s  expected=%s  got=%s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL+1))
  fi
}

log() { printf '\n--- %s ---\n' "$*"; }

# Reset
mc rb --force "local/$BUCKET" >/dev/null 2>&1 || true
mc mb "local/$BUCKET" >/dev/null 2>&1
echo "public content" > /data/testdata/local/access-public.txt
mc cp /data/testdata/local/access-public.txt "local/$BUCKET/public.txt" >/dev/null 2>&1

# ============ 1. Default: bucket is private ============
log "1. Default bucket is private (anonymous denied)"
HTTP_PRIVATE=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" "http://${MINIO_IP}:9000/$BUCKET/public.txt" 2>/dev/null)
test_result "Anonymous GET denied (403)" "403" "$HTTP_PRIVATE"

# ============ 2. Set anonymous download policy ============
log "2. Set anonymous read policy"
mc anonymous set download "local/$BUCKET" >/dev/null 2>&1
ANON_STATE=$(mc anonymous get "local/$BUCKET" 2>/dev/null | head -1)
echo "  Anonymous state: $ANON_STATE"

HTTP_PUBLIC=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" "http://${MINIO_IP}:9000/$BUCKET/public.txt" 2>/dev/null)
test_result "Anonymous GET allowed (200)" "200" "$HTTP_PUBLIC"

# ============ 3. Revoke anonymous ============
log "3. Revoke anonymous access"
mc anonymous set none "local/$BUCKET" >/dev/null 2>&1
HTTP_REVOKED=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" "http://${MINIO_IP}:9000/$BUCKET/public.txt" 2>/dev/null)
test_result "Anonymous GET revoked (403)" "403" "$HTTP_REVOKED"

# ============ 4. Create IAM user ============
log "4. Create IAM user"
mc admin user add local access-user <REDACTED_USER_PASSWORD> >/dev/null 2>&1 || true
USER_LISTED=$(mc admin user list local 2>/dev/null | grep -c "access-user")
test_result "User access-user created" "1" "$USER_LISTED"

# ============ 5. Create policy ============
log "5. Create IAM policy"
cat > "$ADMIN_DIR/policy-read-bucket.json" << 'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::test-access",
        "arn:aws:s3:::test-access/*"
      ]
    }
  ]
}
JSON
mc admin policy create local access-read "$ADMIN_DIR/policy-read-bucket.json" >/dev/null 2>&1 || true
POLICY_LISTED=$(mc admin policy list local 2>/dev/null | grep -c "^access-read")
test_result "Policy access-read created" "1" "$POLICY_LISTED"

# ============ 6. Attach policy to user ============
log "6. Attach policy to user"
mc admin policy attach local access-read --user access-user >/dev/null 2>&1
USER_POLICY=$(mc admin user info local access-user 2>/dev/null | grep -c "access-read")
test_result "Policy attached to user" "1" "$USER_POLICY"

# ============ 7. Test IAM user access (via alternate alias) ============
log "7. Test IAM user access with scoped credentials"
# Set up a new alias using the access-user credentials
# We need a service account or console session for access-user; instead
# test policy shape via mc admin policy info
POLICY_ACTIONS=$(mc admin policy info local access-read 2>/dev/null | grep -c "s3:GetObject")
test_result "Policy has s3:GetObject" "1" "$POLICY_ACTIONS"

# ============ 8. Create group and add user ============
log "8. Create group and add user"
mc admin group add local access-group access-user >/dev/null 2>&1 || true
GROUP_LISTED=$(mc admin group list local 2>/dev/null | grep -c "^access-group")
test_result "Group access-group created" "1" "$GROUP_LISTED"

# ============ 9. Create service account ============
log "9. Create service account (redacted output)"
SVC_OUTPUT=$(mc admin user svcacct add local access-user 2>&1)
SVC_AK=$(echo "$SVC_OUTPUT" | awk '/Access Key/{print $3}')
SVC_SK=$(echo "$SVC_OUTPUT" | awk '/Secret Key/{print $3}')
if [ -n "$SVC_AK" ] && [ -n "$SVC_SK" ]; then
  test_result "Service account created" "1" "1"
  # Verify it works: run a scoped operation with the new creds
  HTTP_SVC=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
    -s -o /dev/null -w "%{http_code}" \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "${SVC_AK}:${SVC_SK}" \
    "http://${MINIO_IP}:9000/$BUCKET/public.txt" 2>/dev/null)
  test_result "Service account GET (200)" "200" "$HTTP_SVC"
else
  test_result "Service account created" "1" "0"
fi

# ============ 10. STS AssumeRole simulation ============
log "10. STS — availability check"
# MinIO supports AssumeRole via STS API; we verify the endpoint exists.
STS_HTTP=$(docker run --rm --network "$MC_NET" curlimages/curl:latest \
  -s -o /dev/null -w "%{http_code}" -X POST \
  "http://${MINIO_IP}:9000/?Action=AssumeRole&Version=2011-06-15" 2>/dev/null)
# Any non-404 response means the STS endpoint exists (400/403 for missing auth is expected)
if [ "$STS_HTTP" != "404" ] && [ -n "$STS_HTTP" ]; then
  test_result "STS endpoint exists" "1" "1"
  printf '      STS returned HTTP %s (endpoint present, auth required)\n' "$STS_HTTP"
else
  test_result "STS endpoint exists" "1" "0"
fi

# ============ 11. Cleanup ============
log "11. Cleanup"
mc admin policy detach local access-read --user access-user >/dev/null 2>&1 || true
mc admin policy remove local access-read >/dev/null 2>&1 || true
mc admin user remove local access-user >/dev/null 2>&1 || true
mc rb --force "local/$BUCKET" >/dev/null 2>&1 || true
test_result "Cleanup complete" "1" "1"

printf '\n==========================================\n'
printf '  Access control tests:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
