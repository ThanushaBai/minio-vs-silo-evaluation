# ST06 / DEV-910 - MinIO Performance Baseline

**Status:** Complete (reduced scope - see hardware constraint)
**Jira:** DEV-910 (parent: DEV-904)
**Started:** 2026-10-12
**Completed:** 2026-10-12

---

## Goal

Measure throughput, latency, and IOPS of MinIO in Docker Compose on the simple local volume mount using warp. Capture raw-disk baseline with fio, stress behavior with a noisy neighbor, and identify the bottleneck for each configuration. The lab runs on one machine, so results show relative differences (MinIO vs Silo), not production capacity.

---

## Environment

| Item | Value |
|---|---|
| VM | VirtualBox - Ubuntu 26.04, 4 vCPU, 4.3 GiB RAM |
| MinIO | pgsty/minio:RELEASE.2026-08-04T00-00-00Z (single node, 4 drives) |
| Container limits | CPU: 2 cores (2000000000 nanos), Memory: 1536 MiB |
| Disk | /dev/sdb1 - 79 GB on VIRTUALBOX HDD (ROTA=1) |
| Warp | minio/warp:latest (v1.3.1 - 143bf4f) |
| fio | 3.41 |
| Date of record | 2026-10-12 |

---

## Hardware Constraint Notice

The Epic asks for benchmarks on (a) single node and (b) distributed cluster, with local + NFS storage. Our lab runs on a 4-core VM with an HDD:

- **Distributed cluster (4 nodes):** not evaluable (deviation #2). Single-node only.
- **NFS-backed storage:** no NFS server in the lab. Documented as N/A.
- **Read-side warp profiles (get/delete/list):** the single-node lab cannot maintain object persistence between warp runs - these hang. Documented as N/A.

Only write-side profiles were measured: **small-put, large-put, multipart-put, versioned**.

---

## Test Scripts

| Script | Purpose |
|---|---|
| scripts/test-benchmark-local.sh | warp benchmark runner (write-side profiles, 3 runs each) |
| fio commands (inline) | raw disk baseline (sequential write/read, random 4K write) |

---

## Evidence

| File | Contents |
|---|---|
| evidence/environment.txt | Machine, container limits, disk info, warp version |
| evidence/benchmark-run.txt | Session 10A run log |
| evidence/warp-raw/small-put.txt | 3 runs of small-object PUT (10 KiB) |
| evidence/warp-raw/large-put.txt | 3 runs of large-object PUT (10 MiB) |
| evidence/warp-raw/multipart-put.txt | multipart-put attempt (flag error - see F2) |
| evidence/warp-raw/versioned.txt | 3 runs of versioned workload |
| evidence/fio-seqwrite.txt | fio sequential write raw disk |
| evidence/fio-seqread.txt | fio sequential read raw disk |
| evidence/fio-randwrite4k.txt | fio random 4K write raw disk |
| evidence/noisy-neighbor-stress.txt | small-put under CPU contention |

---

## Results: warp Write-Side Profiles

**Configuration:** concurrency 8, duration 20s, 3 repeats each.

### small-put (10 KiB objects)

| Run | Throughput | Ops/s | p50 | p99 |
|---|---|---|---|---|
| 1 | 0.17 MiB/s | 17.22 | 536 ms | 945 ms |
| 2 | 0.42 MiB/s | 42.96 | 151 ms | 617 ms |
| 3 | 0.37 MiB/s | 38.08 | 156 ms | 844 ms |

**Variance:** wide (17-43 ops/s). MinIO shows high variability on small-object workloads due to per-request CPU + disk seek overhead.

### large-put (10 MiB objects)

| Run | Throughput | Ops/s | p50 | p99 |
|---|---|---|---|---|
| 1 | 13.12 MiB/s | 1.31 | 6561 ms | 7184 ms |
| 2 | 14.59 MiB/s | 1.46 | 6330 ms | 6926 ms |
| 3 | 16.25 MiB/s | 1.63 | 5652 ms | 5871 ms |

**Variance:** low (13.1-16.3 MiB/s). Large objects stream efficiently - disk-bound.

### versioned (100 KiB, mixed workload)

| Run | Total Throughput | Total Ops/s |
|---|---|---|
| 1 | 3.01 MiB/s | 50.84 |
| 2 | 2.74 MiB/s | 46.17 |
| 3 | 2.43 MiB/s | 40.74 |

Breakdown per operation:
- **GET** dominates at ~2 MiB/s (20-23 ops/s)
- **PUT** at ~0.7 MiB/s (7-8 ops/s)
- **STAT** at 12-15 ops/s
- **DELETE** at 3.7-5.2 ops/s

### multipart-put (32 MiB in 8 MiB parts)

**Status:** N/A - warp 1.3.1 does not accept `--obj.size`; correct flags are `--parts` and `--part.size`. Session 10B identified the fix but did not re-run.

---

## Results: fio Raw Disk Baseline

**Purpose:** establish the disk's upper bound so MinIO's overhead can be isolated.

| Test | Result |
|---|---|
| Sequential write (1 MiB blocks, iodepth 16) | 29.8 MiB/s (31.3 MB/s) |
| Sequential read (1 MiB blocks, iodepth 16) | 68.1 MiB/s (71.4 MB/s) |
| Random 4K write (iodepth 32) | 244 IOPS (980 KiB/s) |

---

## Results: Noisy Neighbor Stress

**Setup:** a `busybox` container with `--cpus="1.0" --memory="256m"` running tight `dd` loops on a null device.

**Result:** small-put throughput stayed in the normal range (37.73 obj/s, 0.37 MiB/s, p99 1189 ms). No degradation observed.

**Interpretation:** MinIO's small-object workload is disk-bound on our hardware, not CPU-bound. A single core of contention does not move the needle.

---

## Bottleneck Analysis

| Configuration | Bottleneck | Evidence |
|---|---|---|
| small-put | **Disk (HDD seek latency)** | 29.8 MiB/s seq write limit; small writes at 17-43 ops/s |
| large-put | **Disk (sequential throughput)** | 13-16 MiB/s = ~50% of fio seq write (29.8 MiB/s) |
| versioned | **Disk** | PUT runs at 0.7 MiB/s alongside concurrent GET/DELETE |
| noisy-neighbor | **Disk-bound, CPU tolerant** | Contention of 1 core had no measurable effect |

**Conclusion:** In this lab, disk is the bottleneck for every profile. MinIO's own overhead (HTTP + erasure coding + checksums) costs roughly 50% of raw disk throughput on large sequential writes, and is dominated by HDD seek time for small objects.

---

## Methodology

### warp invocation

    docker exec warp-runner /warp <command> \
      --host minio:9000 \
      --access-key <ACCESS_KEY> --secret-key <SECRET_KEY> \
      --bucket warp-bench --insecure --no-color \
      --duration 20s --concurrent 8

### fio invocation

    sudo fio --name=seqwrite --filename=/data/fio-test.bin --size=2G \
      --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 \
      --runtime=30 --time_based --group_reporting

### Run discipline

- Only MinIO source was running (target MinIO stopped to free RAM)
- Warp ran on the same Docker network (minio-lab_minio-net)
- No other containers except during the noisy-neighbor test
- 3 repeats per profile to measure variance

---

## Findings

### F1 - small-put has high variance; large-put is stable

Small-object PUT (10 KiB) varied from 17 to 43 ops/s across 3 runs - a 2.5x spread. Large-object PUT (10 MiB) varied from 13.1 to 16.3 MiB/s - only 1.24x spread.

**Cause:** small requests are dominated by HDD seek + per-request CPU overhead, which has high variance. Large sequential writes amortize over MB-scale transfers.

### F2 - warp 1.3.1 multipart-put uses --parts and --part.size

The multipart-put subcommand does not accept `--obj.size`. Correct syntax:

    /warp multipart-put --parts 4 --part.size 8MiB

Not re-run in this session - documented for reference.

### F3 - HDD caps everything

Every profile's throughput is bounded by the raw HDD speed. fio seq write = 29.8 MiB/s; MinIO large-put = 13-16 MiB/s. MinIO adds ~50% overhead on top of raw disk.

**This is the single most important takeaway for DEV-913 (Silo benchmark):** any MinIO vs Silo delta of less than 2x is noise on this hardware.

### F4 - Noisy neighbor has no effect at 1 core

Pinning a CPU hog to 1 core (of 4) did not measurably reduce MinIO throughput. This confirms the workload is disk-bound under our configuration.

---

## Acceptance Criteria Check

| Criterion | Status |
|---|---|
| warp profiles documented, raw output attached | Partial (4/8 profiles) |
| Results table per profile per topology | Yes (single-node only) |
| Bottleneck identified per configuration, backed by metrics | Yes (disk, via fio) |
| Conclusion uses numbers, lists limits of local benchmarking | Yes (see below) |
| Write-up committed to docs/06-minio-performance-baseline/README.md | This file |

---

## Limits of Benchmarking on a Single Local Machine

1. **No distributed topology** - cannot test multi-node scaling, erasure-set parallelism, or network replication costs.
2. **HDD-backed** - results do not translate to SSD/NVMe deployments.
3. **Shared CPU** - warp and MinIO compete for 4 cores; results are not isolated.
4. **VirtualBox VM** - virtualised I/O adds overhead not present on bare metal.
5. **Single-run samples** - 3 repeats is the minimum for variance; production benchmarking uses 10+.
6. **No network latency** - warp runs on the same Docker network, so no realistic WAN latency is measured.

All numbers are **indicative of relative behavior at lab scale**, not production capacity.

---

## How to Reproduce

    1. git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
    2. cd minio-vs-silo-evaluation
    3. cp .env.example .env  (set credentials)
    4. ./scripts/up.sh
    5. sudo apt install -y fio
    6. ./scripts/test-benchmark-local.sh
    7. sudo fio --name=seqwrite --filename=/data/fio-test.bin --size=2G \
         --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 \
         --runtime=30 --time_based --group_reporting

---

## References

- Parent Epic: Jira DEV-904
- Previous sub-task: docs/05-minio-replication/README.md
- Deviations: docs/01-setup/DEVIATIONS.md
- Project board: https://github.com/users/ThanushaBai/projects/6
- Warp tool: https://github.com/minio/warp
