#!/bin/bash
# up.sh — Start the MinIO lab.
# Usage: ./scripts/up.sh

set -e
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Copy .env.example and edit it first:"
  echo "   cp .env.example .env"
  exit 1
fi

echo ">> Starting MinIO lab..."
docker compose --env-file .env -f compose/minio.yml up -d

echo ">> Waiting 20s for healthcheck..."
sleep 20
docker compose --env-file .env -f compose/minio.yml ps

echo ""
echo "MinIO should be reachable at:"
echo "   S3 API:  http://127.0.0.1:9000"
echo "   Console: http://127.0.0.1:9001"
