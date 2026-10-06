#!/bin/bash
# down.sh — Stop the MinIO lab (preserves all data).
# Usage: ./scripts/down.sh

set -e
cd "$(dirname "$0")/.."

echo ">> Stopping MinIO lab (data volumes preserved)..."
docker compose --env-file .env -f compose/minio.yml down

echo ""
echo "Lab stopped. Data remains in /data/minio/."
echo "To destroy data, run: ./scripts/reset.sh"
