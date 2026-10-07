# Deviations from the DEV-904 Epic Specification

Every deviation from the Epic's stated requirements, with justification.

| # | Spec | Deviation | Justification |
|---|---|---|---|
| 1 | Profile B: 8 cores, 16 GB RAM, 100 GB SSD | 4 cores, 4.3 GB RAM, 80 GB HDD | Host hardware ceiling. Approved by lead on 2026-10-06. |
| 2 | 4-node distributed cluster | Single-node, 4 drives | RAM insufficient for 4 nodes. DEV-908 deferred to lead. |
| 3 | SSD-backed storage | HDD-backed (/dev/sdb, ROTA=1) | Host SSD has <25 GB free. Benchmarks labeled "indicative only". |
| 4 | MinIO OSS: RELEASE.2025-10-15T17-29-55Z | pgsty/minio:RELEASE.2026-08-04T00-00-00Z | Official minio/minio Docker Hub images deleted in 2026. Using pgsty community mirror. |
| 5 | Console bound to 127.0.0.1 | Bound to 0.0.0.0 | Needed for host browser access (VM networking separation). |
| 6 | Compose network: migration-net | minio-lab_minio-net (default) | Default compose network kept; renamed network not needed for single-node lab. |
| 7 | Dataset size: 5–10 GB (Profile B) | ~223 MB total | VM has 4.3 GiB RAM; 223 MB covers every category (small/medium/large/versioned/locked/tagged) while preserving space for benchmarks and two copies. |
| 8 | Client binaries run in container on migration-net | pgsty/mc container only (no host install) | Upstream minio/mc image deleted from Docker Hub in 2026. pgsty/mc used for all client operations. |
| 9 | Lifecycle expiry format | Applied as "1d" not "24h" | mcli requires Nd/Ny validity format and lowercase governance/compliance mode names. |
