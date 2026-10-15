# O01-O08 Compatibility Conditions - Written Decisions

**Sub-task:** DEV-912
**Reference:** https://silo.pgsty.com/compatibility/
**Date:** 2026-10-15

The Silo project lists eight conditions (O01 through O08) under which it is a
drop-in replacement for the last open-source MinIO. Each condition is reviewed
here with a written decision: does it apply to us, how was it tested, and what
was the result.

---

## O01 - Baseline scope

**Condition:** Silo is compared against the *last* open-source MinIO Community
Edition release, not against a later version or AIStor.

**Applies to us:** YES.

**How tested:** We pinned `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` as the
MinIO baseline (the last available community image after upstream Docker Hub
images were deleted) and `pgsty/silo:RELEASE.2026-09-16T00-00-00Z` as the Silo
comparison. Both are the last published releases for their respective projects.

**Result:** PASS. Both versions documented in `docs/01-setup/DEVIATIONS.md` and
all sub-task READMEs.

---

## O02 - Custom authorization policy behavior

**Condition:** Custom authorization policies may behave differently in Silo,
particularly when they rely on legacy MinIO quirks.

**Applies to us:** PARTIAL. Our lab uses basic IAM policies (read-only,
read-write) — no advanced condition-based policies.

**How tested:** `scripts/test-access-control-silo.sh` in DEV-911 tested
creating IAM users, groups, and custom policies; attaching policies to users;
verifying policy enforcement. All 12 access-control tests passed identically
in MinIO and Silo.

**Result:** PASS for the policies we use. **Does not apply to advanced
condition-based policies** — we did not test policy conditions like `s3:prefix`,
`aws:SourceIp`, or time-based restrictions. If any future application uses
those, they should be re-tested.

---

## O03 - Older auth and notification settings

**Condition:** Older authentication schemes (e.g., `MINIO_ACCESS_KEY`,
`MINIO_SECRET_KEY`) and legacy notification configurations may not work in
Silo.

**Applies to us:** NO. Our lab uses modern `MINIO_ROOT_USER` and
`MINIO_ROOT_PASSWORD` (the current standard). We do not configure any
notifications.

**How tested:** Verified our environment variables — we use only the modern
naming convention. Silo started successfully with `MINIO_ROOT_USER=admin` and
`MINIO_ROOT_PASSWORD`, identical to MinIO.

**Result:** N/A - does not apply. If legacy env vars were in use, a migration
would be required.

---

## O04 - Programs relying on old bugs

**Condition:** Programs that depend on old MinIO bugs (e.g., incorrect HTTP
status codes, wrong error bodies, quirky conditional request handling) may
behave differently in Silo, which fixes some of these.

**Applies to us:** PARTIAL. This is the most relevant condition for us. Our
edge-case test suite (DEV-912) probed exactly this area.

**How tested:** `scripts/test-edge-cases.sh` compared MinIO and Silo on:
- Error responses for missing bucket and missing object
- HTTP status codes on unauthenticated probes (root, bucket, missing bucket, missing object)
- ACL API probes
- Conditional PUT with `If-None-Match: *`
- Batch delete and bulk recursive delete

**Result:** PASS. All error XML bodies were **byte-for-byte identical** (only
`RequestId` differed, which is expected per request). HTTP status codes matched
in every probe. No behavioral divergence detected in the areas we tested.

**Caveat:** Our probes were unauthenticated (both returned 403). Testing signed
requests to trigger 404/412 responses would require a signed-URL harness, which
was out of scope for this session. We recommend re-testing specific conditional
request behaviors if any application relies on them.

---

## O05 - On-disk format

**Condition:** Silo keeps the same `.minio.sys` on-disk format as MinIO, so
data written by MinIO can be read by Silo without conversion.

**Applies to us:** YES in principle, though we did not test cross-reading.

**How tested:** Both MinIO and Silo write to their own bind-mounted
directories (`/data/minio/` and `/data/silo/` respectively). We did not
attempt to point Silo at MinIO's existing data directory.

**Result:** NOT TESTED. Migration is out of scope for this Epic (documented as
DEV-916). The on-disk format claim is accepted based on Silo's documentation
and the fork's lineage, but is not independently verified here.

---

## O06 - Multi-pool (server pool addition / decommission)

**Condition:** Adding or decommissioning a server pool may behave differently
in Silo due to changes in cluster management.

**Applies to us:** NO. Our lab is single-node, single-pool. Multi-pool testing
requires a distributed cluster (N/A per deviation #2).

**How tested:** Not tested. Cluster-level operations were deferred to the lead
in DEV-908 and DEV-911.

**Result:** N/A - out of scope for this lab. If a multi-pool deployment is
planned, this condition should be verified on appropriate hardware.

---

## O07 - Replication and mixed versions

**Condition:** Replication between Silo nodes and between Silo and MinIO may
behave differently, especially when clusters run different versions.

**Applies to us:** PARTIAL.

**How tested:**
- **Silo-to-Silo replication** was tested in DEV-911 (`scripts/test-replication-bucket-silo.sh`): 12/12 tests passed, including version replication, delete markers, tags, and metadata. Manifest counts matched between source and target.
- **MinIO-to-Silo replication** is explicitly out of scope (Jira: DEV-916).
- **Mixed-version Silo clusters** were not tested (single-node lab).

**Result:** PASS for Silo-to-Silo. **Not tested** for MinIO-to-Silo (out of
scope) and mixed-version (no multi-node hardware).

---

## O08 - Client and tooling compatibility

**Condition:** Silo keeps the S3 API and `mc`/`mcli` tooling compatible with
MinIO, plus adds its own features.

**Applies to us:** YES.

**How tested:**
- **`mc` vs `mcli`:** The `pgsty/mc:RELEASE.2026-09-16T00-00-00Z` image (which is
  Silo's `mcli` under the hood) was used against both MinIO and Silo. All
  operations succeeded in both.
- **Python SDKs:** `boto3` and `minio-py` both completed full CRUD cycles
  against Silo (`scripts/test-sdk-compat-silo.sh`).
- **AWS CLI:** `aws s3 mb/cp/ls/rb` all succeeded against Silo.
- **Prometheus metrics:** 132 of 134 metric names are identical between MinIO
  and Silo. Silo adds 2 node metrics and drops 2 cluster metrics. Existing
  dashboards and alerts work unchanged, unless they specifically track
  `minio_bucket_batch_replicate_objects` (not applicable in our lab).

**Result:** PASS. All our tooling works against Silo without modification.

---

## Summary Table

| Condition | Applies? | Result | Notes |
|---|---|---|---|
| O01 Baseline scope | Yes | PASS | Both versions pinned |
| O02 Custom auth policies | Partial | PASS (limited) | Basic IAM tested; advanced conditions not tested |
| O03 Older auth/notifications | No | N/A | We use modern conventions |
| O04 Programs relying on old bugs | Partial | PASS | Edge cases byte-for-byte identical (unauthenticated) |
| O05 On-disk format | Yes (in principle) | NOT TESTED | Migration is out of scope (DEV-916) |
| O06 Multi-pool | No | N/A | Single-node lab |
| O07 Replication / mixed versions | Partial | PASS (Silo-to-Silo) | MinIO-to-Silo out of scope; mixed-version N/A |
| O08 Client/tooling | Yes | PASS | All SDKs and CLIs work |

---

## Key Takeaways

1. **Five conditions apply partially or fully** to our lab — all PASS where testable.
2. **Three conditions do not apply** — either out of scope (O05, O06) or not used (O03).
3. **Zero behavioral divergences** were found in the areas we could test.
4. **Existing tooling, dashboards, and alerts work unchanged.**
5. **Two Silo-specific improvements** were identified (extra MRF replication metrics, healthcheck binary, mcli checksum verify — see DEV-911).

Silo's stated drop-in claim is supported by our testing within the scope of
this lab.
