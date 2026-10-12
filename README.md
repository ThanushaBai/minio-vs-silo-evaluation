# MinIO vs Silo — Feature-by-Feature Evaluation

**Jira Epic:** DEV-904
**Project Board:** [View board](https://github.com/users/ThanushaBai/projects/6)
**Repo Owner:** ThanushaBai
**Started:** 2026-10-06

---

## Purpose

Upstream **MinIO Community Edition** was archived (read-only) on **2026-04-25**. It receives no further releases or security patches.

**Silo** ([`pgsty/silo`](https://github.com/pgsty/silo)) is a community-maintained MinIO fork by the Pigsty project, positioned as a near drop-in replacement. It keeps:

- The same S3 API surface and `mc`-style tooling (plus its own `mcli`)
- The same `MINIO_*` environment variables and `minio_*` Prometheus metrics
- The same on-disk format (`.minio.sys`)

Silo describes itself as a **conditional** drop-in — compatibility is best-effort, and eight conditions (**O01–O08**) must be checked before switching.

This repository is a **local proof-of-concept lab** that evaluates whether Silo is a **functional replacement** for the last open-source MinIO, feature by feature, backed by side-by-side evidence.

---

## Scope

### In scope

- S3 API compatibility and client behaviour
- Feature parity (versioning, object lock, lifecycle, replication)
- Security, licence and maintenance review
- Benchmarks (indicative — see hardware constraint notice)
- A capability matrix and final recommendation

### Out of scope

- Migration from MinIO to Silo (Jira: DEV-916)
- Nomad / Kubernetes integration (Jira: DEV-932)
- Distributed-mode resilience and healing (Jira: DEV-908)

---

## ⚠️ Hardware Constraint Notice

This lab runs on a **reduced environment below the Epic's Profile B minimum**.

| Resource | Required (Profile B) | Available (this lab) |
|---|---|---|
| CPU | 8 cores | 4 cores |
| RAM | 16 GB | 4.3 GiB |
| Storage | 100 GB SSD | 80 GB HDD (VBox) |

**Consequences:**

- Single-node topology only — no 4-node cluster
- Benchmarks are **indicative only** and labelled as such
- **DEV-908** (distributed mode) is **not evaluated**; deferred to the lead
- Dataset reduced from 5–10 GB to ~223 MB
- All deviations are documented in [`docs/01-setup/DEVIATIONS.md`](docs/01-setup/DEVIATIONS.md)

---

## Status Table

| Sub-task | Description | Status | Doc |
|---|---|---|---|
| DEV-905 | Set up repo, pin versions, build lab | 🟢 Done | [docs/01-setup](docs/01-setup/) |
| DEV-906 | Seed test data + verification toolkit | 🟢 Done | [docs/02-test-data-and-verification](docs/02-test-data-and-verification/) |
| DEV-907 | MinIO feature validation | 🟢 Done | [docs/03-minio-feature-validation](docs/03-minio-feature-validation/) |
| DEV-908 | MinIO distributed mode (resilience, healing) | ⛔ Out of scope | — |
| DEV-909 | MinIO replication validation | 🟢 Done | [docs/05-minio-replication](docs/05-minio-replication/) |
| DEV-910 | MinIO performance baseline | 🟢 Done | [docs/06-minio-performance-baseline](docs/06-minio-performance-baseline/) |
| DEV-911 | Silo functional validation | ⚪ Not started | — |
| DEV-912 | S3 and client compatibility diff | ⚪ Not started | — |
| DEV-913 | Benchmark Silo vs MinIO | ⚪ Not started | — |
| DEV-914 | Security, licence, CVE review | ⚪ Not started | — |
| DEV-915 | Capability matrix + final report | ⚪ Not started | — |

**Legend:** 🟢 Done · 🟡 In Progress · ⚪ Not Started · ⛔ Out of Scope

**Progress:** 5 of 11 sub-tasks complete (DEV-905, DEV-906, DEV-907, DEV-909, DEV-910) — 103 feature tests + 26 replication tests + 4 benchmark profiles, 0 failures.

---

## Repository Layout

```
.
├── compose/                          Docker Compose files
│   ├── minio.yml                     Single-node MinIO (source)
│   └── minio-target.yml              Second MinIO instance (replication target)
├── configs/                          TLS, nginx, prometheus configs (planned)
├── scripts/                          up / down / reset / lab-check / seed-* / manifest-* / test-*
├── manifests/                        Generated manifest CSVs (baseline, comparisons)
├── docs/
│   ├── 01-setup/                     DEV-905 — repo, versions, lab
│   │   ├── README.md
│   │   ├── DEVIATIONS.md             Every deviation from the Epic spec
│   │   ├── evidence/
│   │   └── screenshots/
│   ├── 02-test-data-and-verification/  DEV-906 — seed data + toolkit
│   │   ├── README.md
│   │   └── evidence/
│   ├── 03-minio-feature-validation/  DEV-907 — S3 API + features
│   │   ├── README.md
│   │   └── evidence/
│   ├── 05-minio-replication/         DEV-909 — replication validation
│   │   ├── README.md
│   │   ├── REPLICATION-RUNBOOK.md    Operator runbook
│   │   └── evidence/
│   └── 06-minio-performance-baseline/  DEV-910 — warp + fio benchmarks
│       ├── README.md
│       └── evidence/
├── .env.example                      Placeholder env template (safe to commit)
├── .env.target                       Target MinIO credentials (git-ignored)
├── .gitignore                        Excludes .env, logs, data
└── README.md                         This file
```

---

## How to Reproduce the Lab

### Prerequisites

- Docker Engine 29.x
- Docker Compose v2.x
- At least 4 CPUs, 4 GiB RAM, 80 GB free disk
- `mc` client (optional — runs in container too)

### Steps

```bash
# 1. Clone
git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
cd minio-vs-silo-evaluation

# 2. Configure credentials
cp .env.example .env
# Edit .env with your credentials

# 3. Create data directories
sudo mkdir -p /data/minio/{data1,data2,data3,data4}
sudo chown -R 1000:1000 /data/minio

# 4. Start the lab
./scripts/up.sh

# 5. Verify
docker compose --env-file .env -f compose/minio.yml ps
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/minio/health/live
# Expected: 200
```

**Console:** `http://<VM-IP>:9001`

---

## Seed the Dataset (DEV-906)

```bash
./scripts/seed-data.sh        # 336 files, ~223 MB
./scripts/seed-upload.sh      # 6 demo buckets, 344 objects
./scripts/seed-versioned.sh   # 6 feature buckets (versioning, lock, tags, metadata)
./scripts/seed-config.sh      # lifecycle, policy, notifications, IAM
./scripts/manifest.sh manifests/minio-baseline.csv
./scripts/manifest-self-test.sh
```

---

## Run the Feature Validation (DEV-907)

```bash
./scripts/test-core-s3.sh              # 14 tests — core S3
./scripts/test-metadata-tags.sh        # 11 tests — metadata + tags
./scripts/test-access-control.sh       # 12 tests — policies, IAM, STS
./scripts/test-encryption.sh           # 10 checks — SSE-S3/C/KMS + TLS
./scripts/test-observability.sh        # 21 tests — metrics, logs, health
./scripts/test-versioning.sh           # 15 tests — versioning deep dive
./scripts/test-object-lock.sh          # 17 tests — governance + compliance
./scripts/test-lifecycle.sh            # 10 tests — lifecycle rules
./scripts/test-sdk-compat.sh           # 4 SDKs — boto3, minio-py, aws-cli, mc
```

**Total: 103 tests across the S3 API and MinIO feature set.**

---

## Run the Replication Validation (DEV-909)

```bash
# Start target MinIO first
docker compose --env-file .env.target -f compose/minio-target.yml up -d

# Then run the replication tests
./scripts/test-replication-bucket.sh          # 13 tests — bucket replication
./scripts/test-replication-failure.sh         # 7 tests — failure scenarios + lag
./scripts/test-replication-batch-site.sh      # 6 tests — batch replication + site N/A
```

**Total: 26 tests across bucket, batch, and site replication.** See the [Replication Runbook](docs/05-minio-replication/REPLICATION-RUNBOOK.md) for operational details.

---

## Run the Performance Baseline (DEV-910)

```bash
# Install fio for raw-disk baseline
sudo apt install -y fio

# Run the write-side warp profiles (small-put, large-put, multipart-put, versioned)
./scripts/test-benchmark-local.sh

# Raw disk baseline
sudo fio --name=seqwrite --filename=/data/fio-test.bin --size=2G \
  --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 \
  --runtime=30 --time_based --group_reporting
```

**Results:** see [docs/06-minio-performance-baseline/README.md](docs/06-minio-performance-baseline/README.md). Key figures on this lab's HDD: ~30 MiB/s seq write, ~68 MiB/s seq read, 244 IOPS random 4K. MinIO reaches ~50% of raw disk on large sequential writes.

---

## Security

- **No secrets committed.** `.env` and `.env.target` are git-ignored; only `.env.example` is tracked.
- **Pre-commit hook:** [`gitleaks`](https://github.com/gitleaks/gitleaks) v8.16.0 blocks commits containing secrets.
- **GitHub Secret Scanning** and **Push Protection** are enabled on this repository.
- **A test commit with a fake AWS key was blocked** — evidence in [`docs/01-setup/evidence/gitleaks-test.txt`](docs/01-setup/evidence/gitleaks-test.txt).
- **Service-account and password leaks** in evidence are redacted before commit.

---

## Documentation Rules

Every sub-task has its own folder under `docs/NN-name/` with:

- `README.md` — Goal, Environment, Steps, Results, Findings, Conclusion
- `evidence/` — raw command output as `.txt` files
- `screenshots/` — visual evidence

**No PASS/FAIL claim is made without raw command output backing it.**

---

## Licence Notes

Both MinIO and Silo are licensed under **AGPL-3.0**. Full review in DEV-914.

---

## Links

- **Jira Epic:** DEV-904 (parent)
- **Project Board:** https://github.com/users/ThanushaBai/projects/6
- **Silo upstream:** https://github.com/pgsty/silo
- **Silo docs:** https://silo.pgsty.com/
- **Silo compatibility (O01–O08):** https://silo.pgsty.com/compatibility/
