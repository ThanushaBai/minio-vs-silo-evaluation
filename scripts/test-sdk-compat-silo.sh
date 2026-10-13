#!/bin/bash
# test-sdk-compat.sh — SDK compatibility for DEV-907 (Session 4B).

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

MINIO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minio)
[ -z "$MINIO_IP" ] && { echo "ERROR: MinIO container not found" >&2; exit 1; }

ENDPOINT="http://127.0.0.1:9000"

export MINIO_ENDPOINT="$ENDPOINT"
export MINIO_ACCESS_KEY="$MINIO_ROOT_USER"
export MINIO_SECRET_KEY="$MINIO_ROOT_PASSWORD"

PASS=0
FAIL=0

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

log() { printf '\n--- %s ---\n' "$*"; }

# ============ 1. boto3 SDK ============
log "1. boto3 SDK (Python)"
python3 << 'PYEOF'
import os, sys
import boto3
from botocore.config import Config

endpoint = os.environ["MINIO_ENDPOINT"]
ak = os.environ["MINIO_ACCESS_KEY"]
sk = os.environ["MINIO_SECRET_KEY"]

s3 = boto3.client(
    "s3",
    endpoint_url=endpoint,
    aws_access_key_id=ak,
    aws_secret_access_key=sk,
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    region_name="us-east-1",
)

bucket = "sdk-boto3-test"
try:
    try:
        s3.create_bucket(Bucket=bucket)
    except Exception:
        pass
    s3.put_object(Bucket=bucket, Key="hello.txt", Body=b"hello from boto3")
    objs = s3.list_objects_v2(Bucket=bucket)
    keys = [o["Key"] for o in objs.get("Contents", [])]
    assert "hello.txt" in keys, f"key missing: {keys}"
    resp = s3.get_object(Bucket=bucket, Key="hello.txt")
    body = resp["Body"].read()
    assert body == b"hello from boto3", f"content mismatch: {body}"
    s3.delete_object(Bucket=bucket, Key="hello.txt")
    s3.delete_bucket(Bucket=bucket)
    print("PASS  boto3: create/put/list/get/delete/delete-bucket")
    sys.exit(0)
except Exception as e:
    print(f"FAIL  boto3: {type(e).__name__}: {e}")
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# ============ 2. minio-py SDK ============
log "2. minio-py SDK (Python)"
python3 << 'PYEOF'
import os, sys
from minio import Minio

endpoint = os.environ["MINIO_ENDPOINT"].replace("http://", "")
ak = os.environ["MINIO_ACCESS_KEY"]
sk = os.environ["MINIO_SECRET_KEY"]

client = Minio(endpoint, access_key=ak, secret_key=sk, secure=False)
bucket = "sdk-miniopy-test"

try:
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)
    payload = b"hello from minio-py"
    client.put_object(bucket, "hello.txt", __import__("io").BytesIO(payload), length=len(payload))
    objs = list(client.list_objects(bucket))
    names = [o.object_name for o in objs]
    assert "hello.txt" in names, f"key missing: {names}"
    resp = client.get_object(bucket, "hello.txt")
    body = resp.read()
    resp.close()
    resp.release_conn()
    assert body == payload, f"content mismatch: {body}"
    client.remove_object(bucket, "hello.txt")
    client.remove_bucket(bucket)
    print("PASS  minio-py: create/put/list/get/delete/delete-bucket")
    sys.exit(0)
except Exception as e:
    print(f"FAIL  minio-py: {type(e).__name__}: {e}")
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# ============ 3. aws-cli ============
log "3. aws-cli"
export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_DEFAULT_REGION="us-east-1"

AWS="aws --endpoint-url $ENDPOINT"
BUCKET="sdk-awscli-test"

$AWS s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true

$AWS s3 mb "s3://$BUCKET" >/dev/null 2>&1
MB_RC=$?
$AWS s3 cp /data/testdata/local/small/obj-small-001.bin "s3://$BUCKET/test.bin" >/dev/null 2>&1
CP_RC=$?
LISTED=$($AWS s3 ls "s3://$BUCKET/" 2>/dev/null | grep -c "test.bin")
$AWS s3 rb "s3://$BUCKET" --force >/dev/null 2>&1

if [ "$MB_RC" = "0" ] && [ "$CP_RC" = "0" ] && [ "$LISTED" = "1" ]; then
  test_result "aws-cli: create/put/list/delete-bucket" "1" "1"
else
  test_result "aws-cli: create/put/list/delete-bucket" "1" "0"
  printf '      mb_rc=%s cp_rc=%s listed=%s\n' "$MB_RC" "$CP_RC" "$LISTED"
fi

# ============ 4. mc (mcli) ============
log "4. mc (mcli)"
MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
MC_NET="minio-lab_minio-net"
MC_ENV="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_IP}:9000"

MC_BUCKET="sdk-mc-test"
docker run --rm --network "$MC_NET" -e "$MC_ENV" "$MC_IMAGE" \
  rb --force --dangerous "local/$MC_BUCKET" >/dev/null 2>&1 || true
docker run --rm --network "$MC_NET" -e "$MC_ENV" "$MC_IMAGE" \
  mb "local/$MC_BUCKET" >/dev/null 2>&1
docker run --rm --network "$MC_NET" -v /data/testdata:/data/testdata:ro -e "$MC_ENV" "$MC_IMAGE" \
  cp /data/testdata/local/small/obj-small-001.bin "local/$MC_BUCKET/" >/dev/null 2>&1
MC_LISTED=$(docker run --rm --network "$MC_NET" -e "$MC_ENV" "$MC_IMAGE" \
  ls "local/$MC_BUCKET/" 2>/dev/null | wc -l)
docker run --rm --network "$MC_NET" -e "$MC_ENV" "$MC_IMAGE" \
  rb --force --dangerous "local/$MC_BUCKET" >/dev/null 2>&1
test_result "mc: create/put/list/delete-bucket" "1" "$MC_LISTED"

printf '\n==========================================\n'
printf '  SDK compatibility:  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
printf '==========================================\n'

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
