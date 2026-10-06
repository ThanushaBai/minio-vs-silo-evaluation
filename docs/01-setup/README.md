# ST01 / DEV-905 — Repo, Versions, and Local Lab

**Status:** 🟢 Done
**Jira:** DEV-905 (parent: DEV-904)
**Started:** 2026-10-06
**Completed:** 2026-10-07

---

## Goal

Create the public GitHub repository for this evaluation, pin the versions of MinIO and Silo under test, and bring up a **single-node MinIO lab** with 4 drives on a local bind-mounted volume. This is the baseline against which all later sub-tasks will be compared.

This sub-task also establishes:

- Repository structure and documentation conventions
- Secret-scanning safeguards (gitleaks + GitHub)
- A repeatable "destroy and rebuild" workflow

---

## Environment

| Item | Value |
|---|---|
| **Host OS** | Windows 11 |
| **Host CPU** | Intel i5-1135G7 (4 cores / 8 threads) |
| **Host RAM** | 8 GB |
| **VM** | VirtualBox — Ubuntu 26.04 LTS "Resolute Raccoon" |
| **VM CPU** | 4 vCPU |
| **VM RAM** | 4.3 GiB |
| **VM Data Disk** | 80 GB VDI (on host HDD) — mounted at `/data` |
| **Docker Engine** | 29.1.3 |
| **Docker Compose** | 2.40.3 |
| **MinIO Image** | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` |
| **MinIO Image Digest** | `sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372` |
| **Silo Image (pinned, not yet used)** | `pgsty/silo:RELEASE.2026-09-16T00-00-00Z` |
| **mc/mcli client image** | `pgsty/mc:RELEASE.2026-09-16T00-00-00Z` |
| **gitleaks** | 8.16.0-1build2 (via apt) |
| **Date of record** | 2026-10-06 |

---

## ⚠️ Hardware Constraint Note

This lab is **below the Epic's Profile B** (8 cores / 16 GB RAM / 100 GB SSD).

**Approved reduced scope:** single-node topology, HDD-backed storage, benchmarks labelled *indicative only*, DEV-908 deferred to lead.

Full list: [`DEVIATIONS.md`](DEVIATIONS.md)

---

## Prerequisites

- Docker Engine 29.x
- Docker Compose v2.x
- At least 4 CPUs, 4 GiB RAM, 80 GB free disk
- `gitleaks` installed (for pre-commit hook)
- `gh` CLI authenticated (for issue management)

---

## Step-by-Step Procedure

### Step 1 — Create the repository and folder structure

```bash
mkdir -p ~/minio-vs-silo-evaluation
cd ~/minio-vs-silo-evaluation
git init && git branch -M main
mkdir -p compose configs scripts \
         docs/01-setup/{evidence,screenshots}
touch README.md .gitignore .env.example
```

**Expected:** repo initialised, folders created.
**Actual:** ✅ PASS

---

### Step 2 — Create `.gitignore` and `.env.example`

```bash
cat > .gitignore << 'EOF'
.env
*.log
data/
EOF

cat > .env.example << 'EOF'
MINIO_IMAGE=pgsty/minio
MINIO_TAG=RELEASE.2026-08-04T00-00-00Z
MINIO_ROOT_USER=<ACCESS_KEY>
MINIO_ROOT_PASSWORD=<SECRET_KEY>
EOF
```

**Expected:** `.env` is ignored; `.env.example` has placeholders only.
**Actual:** ✅ PASS — verified with `git status` (`.env` never appears).

---

### Step 3 — Pin image versions

The last official MinIO Community release (`RELEASE.2025-10-15T17-29-55Z`) is **no longer available** — MinIO deleted the Docker Hub images in 2026. Using the community-maintained mirror `pgsty/minio` as the closest available substitute.

| Image | Tag | Digest |
|---|---|---|
| `pgsty/minio` | `RELEASE.2026-08-04T00-00-00Z` | `sha256:b6bfe7239bfc...` |
| `pgsty/silo` | `RELEASE.2026-09-16T00-00-00Z` | *(pinned, not yet pulled)* |
| `pgsty/mc` | `RELEASE.2026-09-16T00-00-00Z` | `sha256:cfc83108c3ab...` |

**Expected:** immutable tags, digests recorded.
**Actual:** ✅ PASS — see [`evidence/minio-digest.txt`](evidence/minio-digest.txt)

---

### Step 4 — Prepare data directories

```bash
sudo mkdir -p /data/minio/{data1,data2,data3,data4}
sudo chown -R 1000:1000 /data/minio
```

**Expected:** 4 directories owned by UID 1000 (MinIO container user).
**Actual:** ✅ PASS

---

### Step 5 — Start MinIO (single node, 4 drives)

```bash
docker compose --env-file .env -f compose/minio.yml up -d
sleep 30
docker compose --env-file .env -f compose/minio.yml ps
```

**Expected:** container status `healthy`.
**Actual:** ✅ PASS — see [`evidence/compose-ps.txt`](evidence/compose-ps.txt)

---

### Step 6 — Verify the S3 API is live

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/minio/health/live
```

**Expected:** `200`
**Actual:** ✅ PASS

---

### Step 7 — Access the Console

- URL: `http://192.168.0.8:9001` (from host browser)
- Login: `admin` / `<REDACTED>`

**Expected:** Console loads, login succeeds.
**Actual:** ✅ PASS — see [`screenshots/console-login.png`](screenshots/console-login.png)

**Note:** The Console port is bound to `0.0.0.0` instead of `127.0.0.1` because of the VM/host networking separation. Documented as deviation #5.

---

### Step 8 — Set up gitleaks pre-commit hook

```bash
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
echo "🔍 Running gitleaks on staged files..."
if ! gitleaks protect --staged --verbose --no-banner 2>&1; then
    echo "❌ COMMIT BLOCKED: gitleaks detected potential secrets."
    exit 1
fi
echo "✅ gitleaks passed — no secrets found"
EOF
chmod +x .git/hooks/pre-commit
```

**Expected:** hook installed and executable.
**Actual:** ✅ PASS

---

### Step 9 — Test the hook blocks a fake secret

```bash
echo 'AWS_ACCESS_KEY_ID=<FAKE_KEY>' > fake_secret.txt
git add fake_secret.txt
git commit -m "test: fake secret (should be blocked)"
```

**Expected:** commit blocked with gitleaks warning.
**Actual:** ✅ PASS — commit blocked. Evidence: [`evidence/gitleaks-test.txt`](evidence/gitleaks-test.txt)

*Note: the fake key was redacted in the evidence file so that the hook itself does not block future commits.*

---

### Step 10 — Enable GitHub Secret Scanning

- Settings → Code security and analysis
- **Secret Protection:** enabled
- **Push protection:** enabled

**Actual:** ✅ PASS — see [`screenshots/github-secret-scanning.png`](screenshots/github-secret-scanning.png)

---

### Step 11 — Persistence test: container restart

Uploaded a 1 MiB random file to the `persist-test` bucket, recorded its SHA256, then ran `docker compose restart` and re-downloaded the object.

```bash
# 1 MiB test file
dd if=/dev/urandom of=/tmp/persist-test.bin bs=1M count=1
ORIG_SHA=$(sha256sum /tmp/persist-test.bin | awk '{print $1}')

# Upload + list + restart + download (see evidence file for full commands)
docker compose --env-file .env -f compose/minio.yml restart

# Compare SHA256 after restart
```

**Expected:** SHA256 matches after restart.
**Actual:** ✅ PASS — identical SHA256 (`50b50210…`).
Evidence: [`evidence/persistence-test.txt`](evidence/persistence-test.txt)

---

### Step 12 — Persistence test: down + up (no `-v`)

Stopped the whole Compose project with `docker compose down` (**no `-v`**), brought it back up, and re-downloaded the same object.

```bash
docker compose --env-file .env -f compose/minio.yml down
docker compose --env-file .env -f compose/minio.yml up -d
# wait for healthy, then re-download and verify checksum
```

**Expected:** SHA256 matches after full down/up.
**Actual:** ✅ PASS — identical SHA256.
Evidence: [`evidence/persistence-test.txt`](evidence/persistence-test.txt)

⚠️ **Warning recorded:** `docker compose down -v` would delete named volumes. Since our
drives are *bind-mounted directories* (`/data/minio/data*`), `-v` alone would **not**
delete them — but we never use `-v` in this lab. Destruction is done explicitly via
[`scripts/reset.sh`](../../scripts/reset.sh).

---

### Step 13 — Rebuild from scratch + timing

Wiped `/data/minio/data*`, then timed a fresh `docker compose up -d` until the container reported `healthy`.

```bash
docker compose --env-file .env -f compose/minio.yml down
sudo rm -rf /data/minio/data1/* /data/minio/data2/* /data/minio/data3/* /data/minio/data4/*
START=$(date +%s)
docker compose --env-file .env -f compose/minio.yml up -d
# poll for health ...
END=$(date +%s); echo "REBUILD TIME: $((END - START)) seconds"
```

**Expected:** reproducible from repo alone, time recorded.
**Actual:** ✅ PASS — **8 seconds** to healthy.
Evidence: [`evidence/rebuild-timing.txt`](evidence/rebuild-timing.txt)

---

## Results Table

| # | Step | Expected | Actual | Status |
|---|---|---|---|---|
| 1 | Repo + folders created | Structure present | OK | ✅ PASS |
| 2 | `.gitignore` + `.env.example` | `.env` ignored | OK | ✅ PASS |
| 3 | Image versions pinned | Tags + digests recorded | OK | ✅ PASS |
| 4 | Data directories | 4 dirs, UID 1000 | OK | ✅ PASS |
| 5 | MinIO starts | Container healthy | Healthy | ✅ PASS |
| 6 | S3 health endpoint | HTTP 200 | 200 | ✅ PASS |
| 7 | Console login | Reachable, logged in | OK | ✅ PASS |
| 8 | gitleaks hook | Installed, executable | OK | ✅ PASS |
| 9 | gitleaks blocks fake secret | Blocked | Blocked | ✅ PASS |
| 10 | GitHub Secret Scanning | Enabled | Enabled | ✅ PASS |
| 11 | Persistence after container restart | SHA256 matches | SHA256 matches | ✅ PASS |
| 12 | Persistence after down + up (no `-v`) | SHA256 matches | SHA256 matches | ✅ PASS |
| 13 | Rebuild from scratch | Reproducible, time recorded | 8 seconds | ✅ PASS |

---

## Findings and Problems

1. **MinIO is no longer on Docker Hub.** The last official Community Edition image (`RELEASE.2025-10-15T17-29-55Z`) was deleted. Workaround: use the community mirror `pgsty/minio`. Recorded as deviation #4.

2. **`minio/mc` image is also gone.** The official `minio/mc` Docker image was removed alongside the server image. Workaround: use `pgsty/mc`, which is Silo's own `mcli` client. Recorded as deviation #8.

3. **Single-node warning is expected.** MinIO logs:
   > `WARNING: Host local has more than 2 drives of set. A host failure will result in data becoming unavailable.`
   This is expected for a single-node lab and is not a bug.

4. **GOMAXPROCS warning.** MinIO logs `GOMAXPROCS(2) < NumCPU(4)`. Caused by the Docker CPU limit (`cpus: "2.0"`). Performance impact is documented in the benchmark sub-task.

5. **Console bound to `0.0.0.0`.** Required to reach the Console from the Windows host browser. Documented as deviation #5.

6. **Pre-commit hook blocks legitimate test artifacts.** The gitleaks evidence file initially contained the fake AWS key it was documenting. Redacted to `AKIA_REDACTED_EXAMPLE` so the hook doesn't self-block future commits.

7. **Credentials never hardcoded in scripts.** Test scripts load `MINIO_ROOT_USER` /
   `MINIO_ROOT_PASSWORD` from `.env` via shell sourcing, and pass them to containers
   via `MC_HOST_local` env variables. The `.env` file is git-ignored.

---

## Conclusion

ST01 is **complete** with documented reduced scope:

- Repo, docs and issue board are in place
- MinIO baseline is running, healthy, and accessible
- Secret-scanning safeguards are active (proven by a blocked test commit)
- Data persists across restart and full down/up
- The lab rebuilds from the repo in **8 seconds**
- All deviations from the Epic spec are recorded in [`DEVIATIONS.md`](DEVIATIONS.md)

**Proceeding to DEV-906 (seed data + verification toolkit).**

---

## How to Reproduce and Clean Up

### Reproduce

```bash
git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
cd minio-vs-silo-evaluation
cp .env.example .env        # edit with your credentials
sudo mkdir -p /data/minio/{data1,data2,data3,data4}
sudo chown -R 1000:1000 /data/minio
./scripts/up.sh
```

### Stop (preserves data)

```bash
./scripts/down.sh
```

### Destroy all data (⚠️ destructive)

```bash
./scripts/reset.sh
```

---

## References

- Silo upstream: https://github.com/pgsty/silo
- Silo docs: https://silo.pgsty.com/
- Silo compatibility (O01–O08): https://silo.pgsty.com/compatibility/
- Parent Epic: Jira DEV-904
- Project board: https://github.com/users/ThanushaBai/projects/6
