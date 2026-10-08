# ST03 / DEV-907 — MinIO Feature Validation

**Status:** In Progress (Session 1 of 4 complete)
**Jira:** DEV-907 (parent: DEV-904)
**Started:** 2026-10-08

---

## Goal

Validate the S3 API surface and MinIO features on the baseline single-node lab, then go deep on versioning, retention, and lifecycle behavior. Every test records the exact command used, the expected result (written before the test), and the observed result. Results feed the capability matrix in DEV-915 and are re-run on Silo in DEV-911.

---

## Environment

| Item | Value |
|---|---|
| VM | VirtualBox - Ubuntu 26.04, 4 vCPU, 4.3 GiB RAM |
| Docker | 29.1.3 |
| Docker Compose | 2.40.3 |
| MinIO | pgsty/minio:RELEASE.2026-08-04T00-00-00Z |
| mc / mcli | pgsty/mc:RELEASE.2026-09-16T00-00-00Z |
| Console | http://192.168.0.8:9001 |
| Date of record | 2026-10-08 |

---

## Session Plan

This sub-task spans four sessions:

| Session | Scope | Status |
|---|---|---|
| **1** | Core S3 + Metadata/Tagging | Complete |
| 2 | Access control + Encryption + Observability | Pending |
| 3 | Versioning + Object lock (deep dive) | Pending |
| 4 | Lifecycle + SDK compatibility + wrap-up | Pending |

---

## Session 1 - Core S3 + Metadata/Tagging

### Test Scripts

| Script | Coverage | Result |
|---|---|---|
| scripts/test-core-s3.sh | 14 core S3 operations | 14/14 PASS |
| scripts/test-metadata-tags.sh | 11 metadata + tag operations | 11/11 PASS |

### Evidence

- evidence/core-s3-output.txt
- evidence/metadata-tags-output.txt

---

### Core S3 - Test Details

| # | Test | Expected | Observed | Status |
|---|---|---|---|---|
| 1 | Bucket create | 1 bucket visible | 1 | PASS |
| 2 | PUT object | Object listed | Yes | PASS |
| 3 | HEAD object (stat size) | 12 bytes | 12 | PASS |
| 4 | GET object (sha256) | Content matches | Match | PASS |
| 5 | Copy object (server-side) | Copy exists | Yes | PASS |
| 6 | Range read (bytes 0-4) | hello | hello | PASS |
| 7 | Multipart upload (7 MB) | 7340032 bytes | 7340032 | PASS |
| 8 | Presigned URL generation | URL with signature | Yes | PASS |
| 9 | Presigned URL fetch (curl) | HTTP 200 | 200 | PASS |
| 10 | List (flat) | 2 objects | 2 | PASS |
| 11 | List (recursive) | 3 objects | 3 | PASS |
| 12 | Batch delete (multiple keys) | 1 remaining | 1 | PASS |
| 13 | Delete single object | 0 remaining | 0 | PASS |
| 14 | Delete bucket | Bucket gone | Gone | PASS |

Total: 14/14 PASS - see evidence/core-s3-output.txt

---

### Metadata & Tagging - Test Details

| # | Test | Expected | Observed | Status |
|---|---|---|---|---|
| 1 | User metadata (3 keys on PUT) | 3 X-Amz-Meta- keys | 3 | PASS |
| 2 | Object tags (3 tags) | 3 tags | 3 | PASS |
| 3 | Verify tag value | env=test | test | PASS |
| 4 | Bucket tags (2 tags) | 2 tags | 2 | PASS |
| 5 | Update existing tag | priority=critical | critical | PASS |
| 6 | Remove one tag | 2 remaining | 2 | PASS |
| 6b | Verify removed tag | 0 matches | 0 | PASS |
| 7 | Metadata survives tag ops | 3 keys | 3 | PASS |
| 8 | Copy preserves metadata | >= 3 keys | 4 (see finding) | PASS |
| 9 | Overwrite resets metadata | 0 keys | 0 | PASS |
| 10 | Cleanup | Bucket gone | Gone | PASS |

Total: 11/11 PASS - see evidence/metadata-tags-output.txt

---

## Findings & MinIO-Specific Behaviors

### F1 - mcli --attr uses semicolons, not commas

Correct usage: mc cp --attr "Owner=alice;Project=demo;Stage=beta" src dst

Wrong usage: mc cp --attr "X-Amz-Meta-Owner=alice,X-Amz-Meta-Project=demo" src dst

mcli automatically prefixes each key with X-Amz-Meta-. Commas get packed into a single value.

### F2 - mc tag remove removes ALL tags

There is no flag to remove just one tag. To remove one tag, re-apply the remaining set with mc tag set.

This differs from the AWS CLI, where you can specify individual tags to remove.

### F3 - Server-side copy of a tagged object adds extra metadata

When you mc cp an object that has object tags, MinIO adds two metadata fields to the copy:

  X-Amz-Meta-X-Amz-Tagging-Count: 2
  X-Amz-Tagging-Count           : 2

Interpretation: MinIO preserves internal tagging-count headers as user metadata on copy. This is an observable deviation from strict AWS S3 semantics and must be checked against Silo in DEV-911.

Impact: Low - metadata is still preserved. Extra keys are informational.

### F4 - mc share download returns two URLs

The Share: URL contains the presigned signature and is the one to use. The URL: line shows the base object URL. Presigned URLs sign the host header, so they must be fetched using the exact URL returned.

### F5 - mc stat prints size with unit suffix

Size is displayed as "12 B" or "7.0MiB", not as a raw number. Scripts must parse the numeric portion (and convert MiB -> bytes when needed).

---

## Conclusion

Session 1 of DEV-907 is complete:

- 14/14 core S3 tests pass
- 11/11 metadata/tagging tests pass
- 5 MinIO/mcli-specific behaviors documented
- Evidence committed for every test

Sessions 2-4 will cover access control, encryption, observability, versioning deep-dives, object lock, lifecycle, and multi-SDK compatibility.

---

## How to Reproduce

  1. git clone https://github.com/ThanushaBai/minio-vs-silo-evaluation.git
  2. cd minio-vs-silo-evaluation
  3. cp .env.example .env
  4. ./scripts/up.sh
  5. ./scripts/test-core-s3.sh
  6. ./scripts/test-metadata-tags.sh

---

## References

- Parent Epic: Jira DEV-904
- Previous sub-task: docs/02-test-data-and-verification/README.md
- Deviations: docs/01-setup/DEVIATIONS.md
- Project board: https://github.com/users/ThanushaBai/projects/6
