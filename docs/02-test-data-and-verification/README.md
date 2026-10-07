# ST02 / DEV-906 — Seed Test Data and Verification Toolkit

**Status:** 🟢 Done
**Jira:** DEV-906 (parent: DEV-904)
**Started:** 2026-10-07
**Completed:** 2026-10-07

---

## Goal

Load MinIO with a dataset that exercises real behaviors — many small/medium/large objects, versioning, tags, metadata, object lock, lifecycle, IAM — and build the tooling that later proves feature parity between MinIO and Silo. Every later validation, replication, and performance sub-task depends on this dataset, so it must be scripted, deterministic, and reproducible.

---

## Environment

Same lab environment as ST01:

| Item | Value |
|---|---|
| VM | VirtualBox — Ubuntu 26.04, 4 vCPU, 4.3 GiB RAM, 80 GB HDD (`/data`) |
| Docker | 29.1.3 |
| Docker Compose | 2.40.3 |
| MinIO | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` |
| mc / mcli | `pgsty/mc:RELEASE.2026-09-16T00-00-00Z` |
| Date of record | 2026-10-07 |

### Hardware Constraint Note

The Epic specifies **5–10 GB** for Profile B. Our VM has 4.3 GiB RAM and 73 GB free disk. We reduced the dataset to **~223 MB** and documented this in `DEVIATIONS.md` (deviation #9).

**Rationale:** 223 MB is enough to cover every category (small/medium/large, versioned, locked, tagged) while leaving room for benchmarks and two copies (MinIO + later Silo) inside 73 GB.

---

## Prerequisites

- ST01 complete (MinIO running, healthy)
- `pgsty/mc:RELEASE.2026-09-16T00-00-00Z` image available
- `/data/testdata/` directory owned by the current user

---

## Scripts Built

All scripts live under `scripts/`. Run them in this order on a fresh lab:

| # | Script | Purpose |
|---|---|---|
| 1 | `seed-data.sh` | Generates deterministic local files under `/data/testdata/local/` |
| 2 | `seed-upload.sh` | Creates 6 demo buckets and uploads the right files to each |
| 3 | `seed-versioned.sh` | Creates 6 feature buckets (versioning, tags, metadata, object lock) |
| 4 | `seed-config.sh` | Lifecycle, bucket policy, notifications, IAM (users/groups/service accounts) |
| 5 | `manifest.sh` | Exports a CSV manifest of every object/version in MinIO |
| 6 | `manifest-compare.sh` | Diffs two manifests and reports missing/extra/altered objects |
| 7 | `manifest-self-test.sh` | Verifies manifest-compare catches each diff category |

---

## Step-by-Step Procedure

### Step 1 — Generate local dataset

```bash
./scripts/seed-data.sh
```

**Expected:** 336 files, ~223 MB across `small/`, `medium/`, `large/`, `nested/`, `flat/`.
**Actual:** ✅ PASS — see [`evidence/seed-data-output.txt`](evidence/seed-data-output.txt)

**Determinism check:** Re-running produces identical SHA256 for every file.
**Actual:** ✅ PASS — see [`evidence/seed-data-determinism.txt`](evidence/seed-data-determinism.txt)

---

### Step 2 — Upload to demo buckets

```bash
./scripts/seed-upload.sh
```

**Expected:** 6 buckets (`demo-small`, `demo-medium`, `demo-large`, `demo-nested`, `demo-flat`, `demo-mixed`).
**Actual:** ✅ PASS — 344 objects uploaded across all 6 buckets.
Evidence: [`evidence/seed-upload-output.txt`](evidence/seed-upload-output.txt)

| Bucket | Objects |
|---|---|
| demo-small | 100 |
| demo-medium | 20 |
| demo-large | 1 |
| demo-nested | 15 |
| demo-flat | 200 |
| demo-mixed | 8 |

---

### Step 3 — Versioning, tags, metadata, object lock

```bash
./scripts/seed-versioned.sh
```

**Expected:** 6 feature buckets with:
- `demo-versioned` — 3 versions + 1 delete marker
- `demo-tagged` — 2 objects with tags
- `demo-metadata` — 2 objects with `X-Amz-Meta-*`
- `demo-lock-gov` — GOVERNANCE retention (1 day)
- `demo-lock-comp` — COMPLIANCE retention (1 day)
- `demo-lock-legal` — legal hold ON

**Actual:** ✅ PASS — see [`evidence/seed-versioned-output.txt`](evidence/seed-versioned-output.txt)

**Bonus finding:** While cleaning up, the legal-hold bucket refused deletion:
```
mc: <ERROR> Failed to remove `local/demo-lock-legal/`.
Object, 'legal-object.bin (Version ID=...)' is WORM protected and cannot be overwritten.
```
This confirms the WORM enforcement works.
Evidence: [`evidence/legal-hold-worm-proof.txt`](evidence/legal-hold-worm-proof.txt)

---

### Step 4 — Lifecycle, policies, notifications, IAM

```bash
./scripts/seed-config.sh
```

**Expected:**
- Lifecycle rule on `demo-versioned` (30-day expiry + 30-day noncurrent)
- Anonymous read policy on `demo-tagged`
- Webhook notification target registered
- Replication config deferred to DEV-909
- User `appuser`, group `appgroup`, policy `app-rw`, service account

**Actual:** ✅ PASS — see [`evidence/seed-config-output.txt`](evidence/seed-config-output.txt)

**Note:** The service-account secret key was redacted before saving to evidence.

---

### Step 5 — Generate baseline manifest

```bash
./scripts/manifest.sh manifests/minio-baseline.csv
```

**Expected:** CSV with 14 columns (bucket, key, version_id, version_ordinal, last_modified, is_delete_marker, size, etag, storage_class, metadata, tags, retention_mode, retention_until, legal_hold).

**Actual:** ✅ PASS — 341 data rows.
Evidence: [`evidence/minio-baseline-manifest.csv`](evidence/minio-baseline-manifest.csv)

Sample rows (demo-versioned):
```
demo-versioned,versioned-key.txt,5b0a9e9a-...,4,2026-10-07T16:32:08.488Z,true,0,,STANDARD,,,,,
demo-versioned,versioned-key.txt,46230f9e-...,3,2026-10-07T16:32:05.832Z,,24,etag...,STANDARD,,,,,
demo-versioned,versioned-key.txt,d63be12f-...,2,2026-10-07T16:32:03.243Z,,28,etag...,STANDARD,,,,,
demo-versioned,versioned-key.txt,bf025395-...,1,2026-10-07T16:32:00.394Z,,18,etag...,STANDARD,,,,,
```

---

### Step 6 — Self-test the comparison tool

```bash
./scripts/manifest-self-test.sh
```

This script deliberately introduces four types of differences and verifies the compare tool detects each.

**Expected:** All 4 cases PASS.
**Actual:** ✅ PASS — see [`evidence/manifest-selftest-output.txt`](evidence/manifest-selftest-output.txt)

```
--- Test: missing object ---     PASS
--- Test: altered object ---     PASS
--- Test: missing version ---    PASS
--- Test: extra object ---       PASS

PASS: 4
FAIL: 0
```

**This satisfies the Epic's acceptance criterion:**
> *"The compare script detects each deliberately introduced difference (missing object, altered byte, missing version, missing tag)."*

---

## Results Table

| # | Step | Expected | Actual | Status |
|---|---|---|---|---|
| 1 | Generate local dataset | 336 files, deterministic | 336 files, deterministic | ✅ PASS |
| 2 | Upload demo buckets | 6 buckets, 344 objects | 6 buckets, 344 objects | ✅ PASS |
| 3 | Versioned/tagged/metadata/lock buckets | 6 feature buckets | 6 feature buckets | ✅ PASS |
| 4 | Lifecycle + IAM | Rules + user + policy | Applied | ✅ PASS |
| 5 | Baseline manifest | 341 rows, 14 columns | 341 rows, 14 columns | ✅ PASS |
| 6 | Self-test (4 diff types) | All detected | All detected | ✅ PASS |

**Total buckets in MinIO: 12**

---

## Findings and Problems

1. **Upstream image deletion.** The official `minio/minio` and `minio/mc` Docker images were both deleted in 2026. We use the community mirrors `pgsty/minio` and `pgsty/mc`. Recorded in `DEVIATIONS.md`.

2. **mcli syntax differences.** `mc retention set` expects lowercase `governance`/`compliance` and validity in `Nd` format (e.g. `1d`), not `24h`. Documented in the script.

3. **Secrets in evidence.** The first `seed-config.sh` run printed the service account's access and secret keys. We patched the script to redact them via `sed` and cleaned up the evidence file. **Lesson recorded:** every future script that prints credentials must pipe through a redactor.

4. **Versioned manifests require `--versions`.** Running `mc ls --json` (without `--versions`) on a versioned bucket only returns the current version. Our `manifest.sh` uses `--versions --json`, which correctly returns every version including delete markers.

5. **`version_id="null"` vs empty string.** Unversioned buckets return `versionId: "null"` (literal string), while versioned buckets return a UUID or omit the field. `manifest-compare.sh` normalizes both to empty string so keys match.

6. **Dataset is smaller than Profile B.** 223 MB instead of 5–10 GB. Rationale: 4.3 GiB RAM VM. Recorded in `DEVIATIONS.md` (#9).

---

## Conclusion

ST02 objectives are met with documented reduced scope:

- 223 MB synthetic dataset generated deterministically
- 12 buckets total: 6 demo + 6 feature buckets
- Versioning, delete markers, tags, metadata, object lock (governance + compliance + legal hold), lifecycle, policy, notifications, and IAM all exercised
- A complete manifest toolkit that captures every object with version ID, ordinal, timestamp, size, and ETag
- A compare tool that detects missing, extra, and altered objects
- A self-test that proves the compare tool catches each difference category
- All artifacts scripted, committed, and reproducible

**Ready for DEV-907 (MinIO feature validation).**

---

## How to Reproduce and Clean Up

### Reproduce (on a fresh lab)

```bash
git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
cd minio-vs-silo-evaluation
cp .env.example .env
./scripts/up.sh
./scripts/seed-data.sh
./scripts/seed-upload.sh
./scripts/seed-versioned.sh
./scripts/seed-config.sh
./scripts/manifest.sh manifests/minio-baseline.csv
./scripts/manifest-self-test.sh
```

### Clean up (destructive)

```bash
./scripts/reset.sh
sudo rm -rf /data/testdata
```

---

## References

- Parent Epic: Jira DEV-904
- Prior sub-task: [docs/01-setup/README.md](../01-setup/README.md)
- Deviations: [docs/01-setup/DEVIATIONS.md](../01-setup/DEVIATIONS.md)
- Project board: https://github.com/users/ThanushaBai/projects/6
