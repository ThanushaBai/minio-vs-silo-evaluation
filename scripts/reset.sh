#!/bin/bash
# reset.sh — Stop the lab AND destroy all data.
# Usage: ./scripts/reset.sh
#
# WARNING: This deletes ALL data in /data/minio/.
# Note: `docker compose down -v` would delete named volumes but NOT bind-mounted
# directories like /data/minio/data*. This script handles that explicitly.

set -e
cd "$(dirname "$0")/.."

echo "WARNING: This will STOP the lab and DELETE all MinIO data in /data/minio/."
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ">> Stopping containers..."
docker compose --env-file .env -f compose/minio.yml down

echo ">> Deleting data in /data/minio/..."
sudo rm -rf /data/minio/data1/* /data/minio/data2/* /data/minio/data3/* /data/minio/data4/*

echo ""
echo "Lab reset complete. Run ./scripts/up.sh to start fresh."
