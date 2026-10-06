# MinIO vs Silo — Feature-by-Feature Evaluation

**Jira Epic:** DEV-904
**Project Board:** https://github.com/users/ThanushaBai/projects/6
**Owner:** ThanushaBai

## Purpose

Upstream MinIO Community Edition was archived on 2026-04-25 and receives no further
security patches. **Silo** (`pgsty/silo`) is a community-maintained MinIO fork by the
Pigsty project, positioned as a near drop-in replacement.

This repo evaluates whether Silo is a functional replacement for the last open-source
MinIO — feature by feature, with side-by-side evidence — before any switch is considered.

## Scope

- **In scope:** S3 API compatibility, features, versioning, object lock, lifecycle,
  client compatibility, security/license review, indicative benchmarks.
- **Out of scope:** Migration (DEV-916), Nomad/Kubernetes (DEV-932),
  distributed-mode resilience (DEV-908 — deferred to lead due to hardware constraints).

## Hardware Constraint Notice

This lab runs on a **reduced environment below Epic Profile B**:

| Resource | Required (Profile B) | Actual |
|---|---|---|
| CPU | 8 cores | 4 cores |
| RAM | 16 GB | 4.3 GB |
| Storage | 100 GB SSD | 80 GB HDD |

**Consequences:**
- Single-node topology only (no multi-node cluster)
- Benchmarks are **indicative only**
- DEV-908 (distributed mode) is **not evaluated** — handled by lead
- Deviations documented in `docs/01-setup/DEVIATIONS.md`

## Status Table

| Sub-task | Description | Status |
|---|---|---|
| [DEV-905](docs/01-setup/) | Set up repo, pin versions, build lab | 🟡 In Progress |
| [DEV-906](docs/02-seed/) | Seed data, verification toolkit | ⚪ Not started |
| [DEV-907](docs/03-minio-features/) | MinIO feature validation | ⚪ Not started |
| [DEV-908](docs/03b-distributed/) | Distributed mode | ⛔ Out of scope (hardware) |
| [DEV-909](docs/04-replication/) | Replication validation | ⚪ Not started |
| [DEV-910](docs/05-minio-bench/) | MinIO performance baseline | ⚪ Not started |
| [DEV-911](docs/06-silo-features/) | Silo functional validation | ⚪ Not started |
| [DEV-912](docs/07-client-compat/) | S3 client compatibility diff | ⚪ Not started |
| [DEV-913](docs/08-silo-bench/) | Silo benchmark vs MinIO | ⚪ Not started |
| [DEV-914](docs/09-security/) | Security, license, CVE review | ⚪ Not started |
| [DEV-915](docs/10-report/) | Final report + recommendation | ⚪ Not started |

Legend: 🟢 Done · 🟡 In Progress · ⚪ Not Started · ⛔ Out of Scope

## Repo Layout

compose/ Docker Compose files (MinIO and Silo)
configs/ TLS certs, nginx, prometheus configs
scripts/ up / down / reset / lab-check scripts
docs/ One folder per sub-task
NN-name/
README.md Goal, Environment, Steps, Evidence, Findings
evidence/ Raw command output (text)
screenshots/ Visual evidence

## How to Reproduce

```bash
git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
cd minio-vs-silo-evaluation
cp .env.example .env
# Edit .env with your credentials
docker compose --env-file .env -f compose/minio.yml up -d
Security

    No secrets committed. .env is git-ignored; only .env.example is committed.

    Pre-commit hook: gitleaks (v8.16.0) blocks commits with secrets.

    GitHub secret scanning enabled on this repo.

License

Evaluation repository. MinIO and Silo are AGPL-3.0.
