#!/bin/bash
# test-benchmark-local.sh — MinIO performance baseline with warp (DEV-910, Session 10A).
# Note: read-side (get/delete/list) profiles require a stable object store; on this
# single-node lab those tests hang, so they are documented as N/A. Only write-side
# profiles (put, multipart-put, versioned) are measured.

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

WARP_IMAGE="minio/warp:latest"
WARP_CONTAINER="warp-runner"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

mc() {
  docker run --rm --network "$MC_NET" \
    -v "$MC_CFG_VOL":/root/.mc \
    pgsty/mc:RELEASE.2026-09-16T00-00-00Z "$@"
}

mc alias set bench "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1

WARP_BUCKET="warp-bench"
EVIDENCE_DIR="docs/06-minio-performance-baseline/evidence"
RESULTS_DIR="$EVIDENCE_DIR/warp-raw"
mkdir -p "$RESULTS_DIR"

log() { printf '\n=== %s ===\n' "$*"; }
hr()  { printf -- '----------------------------------------\n'; }

mc rb --force --dangerous "bench/$WARP_BUCKET" >/dev/null 2>&1 || true
mc mb "bench/$WARP_BUCKET" >/dev/null 2>&1

docker stop "$WARP_CONTAINER" >/dev/null 2>&1 || true
docker rm -f "$WARP_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$WARP_CONTAINER" --network "$MC_NET" \
  --entrypoint sh \
  "$WARP_IMAGE" -c "sleep infinity" >/dev/null

sleep 2
docker ps --format "{{.Names}}" | grep -q "$WARP_CONTAINER" || { echo "ERROR: warp container failed to start"; exit 1; }

warp() {
  docker exec "$WARP_CONTAINER" /warp "$@"
}

WARP_COMMON="--host minio:9000 --access-key ${MINIO_ROOT_USER} --secret-key ${MINIO_ROOT_PASSWORD} --bucket ${WARP_BUCKET} --insecure --no-color"

DURATION="20s"
CONCURRENCY="8"

run_profile() {
  local profile="$1" cmd="$2" extra="${3:-}"
  log "Profile: $profile"
  local out="$RESULTS_DIR/${profile}.txt"
  : > "$out"

  for run in 1 2 3; do
    echo "  --- Run $run ---"
    {
      echo "########## Profile: $profile  Run: $run ##########"
      echo "cmd: /warp $cmd $extra"
      echo ""
      warp $cmd $WARP_COMMON $extra --duration "$DURATION" --concurrent "$CONCURRENCY" 2>&1 || echo "(error: warp exited non-zero)"
      echo ""
    } >> "$out"
    echo "    run $run done"
  done
}

run_profile "small-put" "put" "--obj.size 10KiB"
run_profile "large-put" "put" "--obj.size 10MiB"
run_profile "multipart-put" "multipart-put" "--obj.size 32MiB --part.size 8MiB"
run_profile "versioned" "versioned" "--obj.size 100KiB"

docker stop "$WARP_CONTAINER" >/dev/null 2>&1
docker rm -f "$WARP_CONTAINER" >/dev/null 2>&1
mc rb --force --dangerous "bench/$WARP_BUCKET" >/dev/null 2>&1 || true

hr
log "Session 10A complete"
ls -la "$RESULTS_DIR"

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
