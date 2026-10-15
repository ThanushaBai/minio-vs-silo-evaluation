#!/bin/bash
# test-benchmark-silo.sh — Silo performance baseline (DEV-913).

set -uo pipefail
cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo "ERROR: .env not found" >&2; exit 1; }
set -a; . ./.env; set +a

# Fix: MC_IMAGE was never defined
MC_IMAGE="pgsty/mc:RELEASE.2026-09-16T00-00-00Z"
WARP_IMAGE="minio/warp:latest"
WARP_CONTAINER="warp-runner-silo"
MC_NET="minio-lab_minio-net"
MC_CFG_VOL="mc-config-shared"

mc() {
  docker run --rm --network "$MC_NET" \
    -v "$MC_CFG_VOL":/root/.mc \
    "$MC_IMAGE" "$@"
}

WARP_BUCKET="warp-bench-silo"
EVIDENCE_DIR="docs/09-silo-performance-comparison/evidence"
RESULTS_DIR="$EVIDENCE_DIR/warp-raw"
mkdir -p "$RESULTS_DIR"

log() { printf '\n=== %s ===\n' "$*"; }
hr()  { printf -- '----------------------------------------\n'; }

# Setup bucket on Silo
mc alias set silo http://silo:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1
mc rb --force --dangerous "silo/$WARP_BUCKET" >/dev/null 2>&1 || true
mc mb "silo/$WARP_BUCKET" >/dev/null 2>&1

# Start long-lived warp container
docker stop "$WARP_CONTAINER" >/dev/null 2>&1 || true
docker rm -f "$WARP_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$WARP_CONTAINER" --network "$MC_NET" \
  --entrypoint sh "$WARP_IMAGE" -c "sleep infinity" >/dev/null

sleep 2
docker ps --format "{{.Names}}" | grep -q "$WARP_CONTAINER" || { echo "ERROR: warp container failed"; exit 1; }

warp() {
  docker exec "$WARP_CONTAINER" /warp "$@"
}

WARP_COMMON="--host silo:9000 --access-key ${MINIO_ROOT_USER} --secret-key ${MINIO_ROOT_PASSWORD} --bucket ${WARP_BUCKET} --insecure --no-color"

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
run_profile "versioned" "versioned" "--obj.size 100KiB"

# Container stats snapshot
log "Container stats (Silo)"
{
  echo "=== Container stats snapshot ==="
  echo "Date: $(date -Iseconds)"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" silo
} > "$EVIDENCE_DIR/container-stats.txt"

cat "$EVIDENCE_DIR/container-stats.txt"

# Cleanup
docker stop "$WARP_CONTAINER" >/dev/null 2>&1
docker rm -f "$WARP_CONTAINER" >/dev/null 2>&1
mc rb --force --dangerous "silo/$WARP_BUCKET" >/dev/null 2>&1 || true

hr
log "Silo benchmark complete"
ls -la "$RESULTS_DIR"

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
