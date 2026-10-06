# ST01 / DEV-905 — Repo, Versions, and Local Lab

## Goal
Create the public GitHub repo, pin versions under test, and bring up a single-node MinIO container on a local bind-mounted volume as the baseline for the evaluation.

## Environment

| Item | Value |
|---|---|
| Host | Windows 11, i5-1135G7, 8 GB RAM |
| VM | VirtualBox — Ubuntu 26.04, 4 vCPU, 4.3 GiB RAM, 80 GB HDD |
| Docker | 29.1.3 |
| Docker Compose | 2.40.3 |
| MinIO image | pgsty/minio:RELEASE.2026-08-04T00-00-00Z |
| MinIO digest | sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372 |
| Silo image (pinned for later) | pgsty/silo:RELEASE.2026-09-16T00-00-00Z |
| gitleaks | 8.16.0-1build2 |
| Date | 2026-10-06 |

## Hardware Constraint Note
Below Epic Profile B. Reduced lab approved by lead. See DEVIATIONS.md.

## Prerequisites
- Docker Engine 29.x and Compose v2
- 4 CPUs, 4 GB+ RAM, 80 GB free disk

## Steps

### 1. Clone and prepare
git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
cd minio-vs-silo-evaluation
cp .env.example .env

Expected: repo cloned, .env created. Actual: PASS

### 2. Start MinIO
docker compose --env-file .env -f compose/minio.yml up -d
sleep 30
docker compose --env-file .env -f compose/minio.yml ps

Expected: container healthy. Actual: PASS — see evidence/compose-ps.txt

### 3. Verify S3 API
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/minio/health/live

Expected: 200. Actual: PASS

### 4. Console access
URL: http://192.168.0.8:9001 (host browser)
Login: admin / REDACTED
Actual: PASS — screenshot in screenshots/

### 5. Gitleaks block test
echo 'AWS_ACCESS_KEY_ID=AKIA_REDACTED_EXAMPLE' > fake_secret.txt
git add fake_secret.txt
git commit -m "test"

Expected: commit blocked. Actual: PASS — evidence/gitleaks-test.txt

## Results Table

| Step | Description | Expected | Actual | Status |
|---|---|---|---|---|
| 1 | Repo + env | Cloned | OK | PASS |
| 2 | MinIO startup | Healthy | Healthy | PASS |
| 3 | S3 health endpoint | 200 | 200 | PASS |
| 4 | Console login | Reachable | Reachable | PASS |
| 5 | Gitleaks block | Blocked | Blocked | PASS |

## Findings
- MinIO pgsty/minio starts cleanly on 4 drives.
- Warning about drives in set — expected for single-node.

## Conclusion
ST01 objectives achieved with documented reduced scope. Ready for DEV-906.

## How to Reproduce and Clean Up
docker compose --env-file .env -f compose/minio.yml up -d
docker compose --env-file .env -f compose/minio.yml down
sudo rm -rf /data/minio/data*    # WARNING: destructive
