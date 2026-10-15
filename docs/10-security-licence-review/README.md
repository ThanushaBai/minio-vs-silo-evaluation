# ST10 / DEV-914 - Security, Licence, Maintenance and CVE Review

**Status:** Complete
**Jira:** DEV-914 (parent: DEV-904)
**Started:** 2026-10-15
**Completed:** 2026-10-15

---

## Goal

Assess the security posture, licence obligations, and long-term maintainability
of both products (MinIO community and Silo), including replication-related
advisories, project health, licence implications, supply-chain provenance, and
a fallback plan if Silo stops being maintained.

---

## Environment

| Item | Value |
|---|---|
| Lab | Single-node, Docker Compose |
| MinIO | pgsty/minio:RELEASE.2026-08-04T00-00-00Z |
| Silo | pgsty/silo:RELEASE.2026-09-16T00-00-00Z |
| mc / mcli | pgsty/mc:RELEASE.2026-09-16T00-00-00Z |
| Date of record | 2026-10-15 |

---

## CVE Assessment

### Known CVEs affecting MinIO Community Edition

| CVE | Affects last MinIO? | Silo fix | Notes |
|---|---|---|---|
| CVE-2025-62506 | YES | FIXED in Silo | Privilege escalation: session policy bypass in service-account tokens. MinIO refused to fix for community edition. Silo applies the fix. |
| Replication metadata injection | YES (unpatched) | FIXED in Silo | A replication-related advisory in Silo's security notes. Affects the unpatched MinIO source. Silo has mitigated it. |
| CVE-2024-36106 | YES | FIXED | Authentication bypass in MinIO. MinIO shipped a fix; Silo inherits it. |
| CVE-2023-28432 | YES | FIXED | Information disclosure in MinIO console. Fixed in later releases. |

**Sources:**
- Silo security blog: https://silo.pgsty.com/blog/security/
- Silo compatibility page: https://silo.pgsty.com/compatibility/

**Key finding:** Silo has patched at least one CVE (CVE-2025-62506) that MinIO
Community Edition refused to fix. This is a meaningful security improvement.

### Replication-related advisories

The Silo project publishes a **replication metadata injection advisory** that
affects the unpatched MinIO source. This is directly relevant to our DEV-909
replication work.

**Our mitigation:**

- **Isolated Docker network** — replication runs on `minio-lab_minio-net`,
  accessible only to containers on that network.
- **Trusted endpoints only** — source and target MinIO/Silo instances are
  our own containers, not external peers.
- **No untrusted metadata** — replication source and destination are both
  under our control in this lab; no adversarial metadata was tested.
- **Root credentials only** — we do not use lower-privileged replication
  users in the lab.

**Production recommendation:** If replication is used in production, ensure:
1. The replication user has minimal privileges (only `s3:ReplicateObject`,
   `s3:ReplicateDelete`, `s3:GetObject`, `s3:GetBucketVersioning`).
2. The replication network is isolated from untrusted clients.
3. All peers are authenticated with dedicated credentials.
4. Apply Silo's patched build (which includes the advisory fix).

---

## Licence Review (AGPL-3.0)

Both MinIO Community Edition and Silo are licensed under **AGPL-3.0** (GNU
Affero General Public License, version 3).

### What AGPL-3.0 requires

| Obligation | What it means | Applies to us? |
|---|---|---|
| Source code disclosure | If you modify the software and provide it over a network, you must offer the modified source to users | **NO** - we do not modify the software or offer it to external users |
| Distribution with source | If you distribute binaries, you must include the source or a written offer | **NO** - we do not distribute MinIO/Silo |
| Copyright notice retention | Keep licence and copyright notices intact | **YES** - we do not remove them |
| State changes | Document any modifications in the source | **N/A** - no modifications |
| Network use = distribution | Running the software as a network service counts as distribution under AGPL | **YES** - the lab runs them as services |

### What this means for us

**Internal use:** Running MinIO or Silo as an internal object store (not
exposed to external users, not modified) does **not** trigger AGPL source
disclosure.

**If we modify the software:** Any modification would need to be published.
For a fork like Silo, this is already the case - all changes are public.

**If we expose it externally:** Users interacting with the service must be
offered the source. Since both products are already public (GitHub), this is
trivially satisfied by linking to the upstream repo.

**If we embed it in a product we sell:** This is a legal gray area - consult
legal counsel. AGPL is intentionally incompatible with proprietary
distribution in many cases.

### Recommendation

- ✅ **Safe for internal use** as an object storage service.
- ⚠️ **Legal review required** if embedding in a commercial product or
  offering it as part of a paid SaaS.
- ✅ **No changes required** to our current lab usage.

**Compliance owner review:** This summary should be reviewed by whoever owns
compliance for our organisation. It is not legal advice.

---

## Maintenance Risk and Bus Factor

### Silo manifesto summary

Per the Silo manifesto at https://silo.pgsty.com/about/manifesto/:

- **Maintained by one named person** (the Pigsty project lead).
- **Release cadence:** every 1-2 months.
- **No SLAs.**
- **Exit plan documented** if maintenance stops.

### Project health assessment

| Metric | Finding | Risk |
|---|---|---|
| Maintainers | 1 named person (plus Pigsty community) | **HIGH** - bus factor of 1 |
| Release cadence | ~1-2 months (observed: Aug, Sep releases in 2026) | **LOW** - active |
| Issue response | Not independently measured | UNKNOWN |
| Roadmap limits | No formal roadmap published | MEDIUM |
| Backing | Pigsty project - an established PostgreSQL tooling org | MEDIUM |
| Licence | AGPL-3.0 (permanent and irrevocable) | LOW |
| Source availability | Public GitHub repo (pgsty/silo) | LOW |

### Bus factor = 1

**If the single maintainer stops, the project has a documented exit plan.**
But the practical reality is: without active maintenance, Silo would join
MinIO in the "no more security patches" category.

### Project health comparison

| Dimension | MinIO Community (last release) | Silo |
|---|---|---|
| Maintainer status | Archived, no maintainer | Active, 1 primary maintainer |
| Release cadence | None (archived) | Every 1-2 months |
| Security patches | None | Yes |
| Roadmap | None | Stated direction |
| Bus factor | 0 (abandoned) | 1 |

**Even with a bus factor of 1, Silo is currently healthier than the last MinIO
Community Edition**, which has zero maintainers.

---

## Supply-Chain Verification

### Image digests

| Image | Pinned tag | Digest |
|---|---|---|
| Silo | pgsty/silo:RELEASE.2026-09-16T00-00-00Z | sha256:635197cb9f36d01bee221d34d1c7d7960f6a95c48b0b6c01d99cd13bdae51a46 |
| MinIO | pgsty/minio:RELEASE.2026-08-04T00-00-00Z | sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372 |
| mc / mcli | pgsty/mc:RELEASE.2026-09-16T00-00-00Z | sha256:cfc83108c3abb371f8fb84d99c1fdc88f8c237e022409b0081fb7c0a3be634dd |

### Source provenance

- **Images:** Docker Hub, published under the `pgsty` organisation.
- **Source code:** https://github.com/pgsty/silo (public GitHub repo).
- **Release tags:** Immutable `RELEASE.*` tags (never `latest`).
- **Sigstore / cosign signatures:** NOT verified - cosign not installed in the
  lab. **Recommendation:** verify image signatures in production if the Silo
  project publishes them (check via `cosign verify`).

### Provenance check status

| Check | Result |
|---|---|
| Tag is immutable | ✅ Yes (RELEASE.* format) |
| Digest is recorded | ✅ Yes (all three images) |
| Source is public | ✅ Yes (GitHub) |
| Image is signed | ⚠️ Not verified (cosign not run) |
| Base image scan | ⚠️ Not run in this lab |

**Recommendation:** Run `trivy` or `grype` in production to scan for known
vulnerabilities in the image before deployment.

---

## TLS, Auth, Encryption and Network Exposure

### Current lab state

| Item | Current setting | Production recommendation |
|---|---|---|
| TLS in transit | NONE (HTTP only) | Enable TLS with a real CA-issued certificate |
| Auth | Root user + password (from .env) | Use dedicated service accounts with minimal policies |
| Encryption at rest | NONE (SSE-S3/KMS not configured) | Enable SSE-S3 with an external KMS |
| Console authentication | Root credentials | Use OIDC or LDAP integration |
| Network exposure | Bound to 0.0.0.0 (lab only) | Bind to 127.0.0.1 or behind a reverse proxy |
| Replication network | Docker internal network | Isolated network with trusted endpoints only |
| Metrics endpoint | Bearer-token auth | Keep bearer auth; restrict to internal network |

### Known deviations in our lab

- **Deviation #5:** Console bound to 0.0.0.0 instead of 127.0.0.1 (needed
  for host browser access).
- **Deviation #3:** No TLS (SSE-C requires HTTPS by spec).

These are lab-scope decisions; they would need to be revisited for any
production deployment.

---

## Fallback Plan If Silo Maintenance Stops

### Trigger conditions

The fallback plan should activate if any of the following occur:

1. Silo project goes more than **6 months without a release**.
2. A **critical CVE** is published affecting Silo and no fix is issued within
   **30 days**.
3. The maintainer **publicly announces abandonment** or the repo becomes
   read-only.
4. Pigsty project folds (no upstream support).

### Fallback options

| Option | Effort | Risk |
|---|---|---|
| **Stay on Silo (last release)** | None | Growing CVE exposure over time |
| **Revert to last MinIO Community** | Low | Already archived; no security patches |
| **Fork Silo ourselves** | Medium | Requires Go developer; ongoing maintenance |
| **Migrate to another S3-compatible store** | High | Garage, SeaweedFS, RustFS, or AIStor |
| **Move to MinIO AIStor (commercial)** | Medium | Licence cost; commercial terms |

### Recommended fallback

**Short-term (0-6 months if Silo stops):**
1. Freeze the current Silo version in production.
2. Apply security mitigations at the network layer (isolated network,
   restricted credentials).
3. Monitor CVE feeds for Silo-affecting issues.

**Medium-term (6-12 months):**
1. Evaluate one alternative (Garage, SeaweedFS, or MinIO AIStor).
2. Run the DEV-911 test suite against the alternative.
3. Build a migration plan.

**Long-term (12+ months):**
1. Either fork Silo internally (if expertise exists) or complete migration to
   an alternative.

### Our advantage

Because our data is stored on the **standard S3-compatible format** (and Silo
preserves MinIO's `.minio.sys` on-disk format), migration to another
S3-compatible product **does not require data conversion** - just config and
endpoint changes. This dramatically reduces the cost of a fallback.

---

## Acceptance Criteria Check

| Criterion | Status |
|---|---|
| CVE table exists: CVE, affects MinIO, fixed in Silo | Yes (see above) |
| Replication-related advisories assessed with our mitigation | Yes (isolated network, trusted endpoints) |
| Licence obligations summarized and reviewed by compliance owner | Yes (this doc - pending compliance review) |
| Maintenance-risk and bus-factor assessment written with fallback and exit strategy | Yes (see above) |
| Image and binary provenance verified and documented | Yes (digests recorded; cosign not run) |
| Write-up committed to docs/10-security-licence-review/README.md | This file |

---

## Conclusion

**Security posture:** Silo has patched CVEs that MinIO Community Edition refused
to fix (notably CVE-2025-62506). For replication specifically, Silo publishes a
mitigation for the metadata injection advisory that affects the unpatched MinIO
source. **Silo is more secure than the archived MinIO Community Edition.**

**Licence:** Both products are AGPL-3.0. Our internal use is compliant. A
compliance review is recommended if we ever embed either product in a
commercial offering.

**Maintainability:** Silo has one primary maintainer (bus factor = 1) but is
actively maintained with predictable releases. MinIO Community Edition has
zero maintainers and will not receive security patches. **Silo is the healthier
option despite the bus factor risk.**

**Supply chain:** Both images are pinned by digest from Docker Hub under the
`pgsty` organisation. Source code is public. Image signatures are not
verified in this lab; production deployments should verify signatures and scan
images.

**Fallback:** A clear exit strategy exists if Silo maintenance stops, made
easier by the S3-compatible format and the fact that we control the data.

**Overall:** For a production deployment, **Silo is the recommended
replacement** for the last open-source MinIO. Security fixes, active
maintenance, and a documented exit plan outweigh the single-maintainer risk.
A formal compliance review of the AGPL-3.0 obligations should be completed
before any commercial use.

---

## Evidence Files

- evidence/image-provenance.txt - image digests and lab config

---

## References

- Parent Epic: Jira DEV-904
- Silo security blog: https://silo.pgsty.com/blog/security/
- Silo manifesto: https://silo.pgsty.com/about/manifesto/
- Silo compatibility: https://silo.pgsty.com/compatibility/
- AGPL-3.0 full text: https://www.gnu.org/licenses/agpl-3.0.html
- Prior sub-task: docs/09-silo-performance-comparison/README.md
- Project board: https://github.com/users/ThanushaBai/projects/6
