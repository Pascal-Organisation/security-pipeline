# Target architecture (architectural goal)

Status: **binding goal**, adopted 2026-11-09 (D-40). Owner: @pascal05. The infrastructure goal (IDs `H-*`) lives in
the operator's private infrastructure repository.

A PR that moves away from a goal needs a decision in [decisions.md](decisions.md) naming the goal ID. Current state
is in the [README](../README.md) and `docs/*.md`; task IDs such as `2.2` refer to a private roadmap.

Constraints: **zero cost** (GitHub Free organisation, free/open-source tools, own hardware), **one maintainer**,
**security as strict as these allow**.

## 1. Principles

Canonical here; the infrastructure goal inherits them.

| ID | Principle | Consequence |
|---|---|---|
| P1 | **Fail closed** | A missing signature, attestation, check result or policy match blocks; no "warn and continue" for trust decisions. |
| P2 | **Everything that runs is signed or pinned** | Own images: keyless signature from this pipeline. Third-party images and actions: immutable digest/SHA in git. |
| P3 | **Trust is an identity, not a location** | Consumers trust "built by `build-container.yml` of this repo, from `main`, via GitHub OIDC", never a registry, tag or network. |
| P4 | **Separate trust domains** | Public code never runs on own hardware; private repos build on ephemeral runners per trust domain; CI and runtime never share a cluster. |
| P5 | **Least privilege by default** | `permissions: {}` per workflow, scoped per job; short-lived (OIDC) tokens; no long-lived cloud keys. |
| P6 | **Git is the source of truth** | Policies, pins, manifests and settings expectations are in git and reviewed; live state is checked for drift. |
| P7 | **Evidence over assertion** | Every release carries signature, SBOM, provenance and vulnerability scan bound to the image digest. |
| P8 | **One place for tools and policy** | Scanners, thresholds and exceptions live here; callers pin a release commit and add nothing. |
| P9 | **Exceptions expire** | Every exception has an owner, reason and expiry date; expired ones are reported. |
| P10 | **Free and reproducible over clever** | Prefer platform features and open-source tools; document manual steps; automate what repeats. |

## 2. Trust domains

Flow: repo (GitHub-hosted runner for public, ephemeral self-hosted runner for private) builds an untrusted image tar; the GitHub-hosted publish job re-hashes, scans and pushes it; the GitHub-hosted sign job signs it keylessly (OIDC, Rekor); GHCR holds image, signature, SBOM, provenance and vulnerability attestation; the runtime's admission policy (fail-closed) accepts it and pulls updates.

| Domain | Runs | May hold | Must never |
|---|---|---|---|
| Public CI | Public repos, GitHub-hosted | `GITHUB_TOKEN` (read), OIDC for signing | Run on own hardware; read private packages beyond read access |
| Private CI | Private repos, ephemeral self-hosted runners | Read token for the private toolbox | Reach the LAN, the cluster API or another domain's cache |
| Publish | Separate GitHub-hosted job (D-43) | `GITHUB_TOKEN` with `packages: write` | Execute repo code or Dockerfiles; trust a digest or tag from the build job |
| Signing | Separate GitHub-hosted job | OIDC token for Fulcio | Execute repo code or Dockerfiles |
| Registry | GHCR | Images, signatures, attestations | Be trusted by itself (P3) |
| Runtime | Consumers (app cluster) | Read-only pull credentials | Accept anything that fails the deploy contract (4.5) |

## 3. Reading the goal tables

Status: **Done**, **Merged** (on `main`, ships next release), **Partial**, **Planned**, **Accepted risk** (section 6).
"Verify" is the evidence for re-checking a goal.

## 4. Goal states

### 4.1 Source and repository governance

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-S1 | Public repos: default branch protected by a ruleset (PR, no force-push/deletion, check `security-gate`, strict checks, stale approvals dismissed, conversations resolved, signed commits) | `gh api repos/<r>/rulesets/<id>`; `fleet-drift.yml` | Done (approvals = 0, section 6) |
| G-S2 | `CODEOWNERS` in every repo covering `.github/`, `toolbox/`, `renovate/`, admission policies | file present | Done |
| G-S3 | Release tags `v*` signed and immutable (tag ruleset, immutable releases) | `git tag -v vX.Y.Z`; release settings | Partial (immutable releases: owner setting; v3.3.0 is an unsigned lightweight tag, D-44) |
| G-S4 | Org allows only GitHub-owned actions, `Pascal-Organisation/*` and an explicit list; every `uses:` pinned to a full SHA | `gh api orgs/<org>/actions/permissions` | Done |
| G-S5 | Fork PRs from external contributors need approval before CI | repo Actions settings | Done |
| G-S6 | Push protection on public repos; TruffleHog on every push/PR, full history weekly | settings, `ci.yml` | Done |
| G-S7 | `SECURITY.md` and private vulnerability reporting | repo settings | Done |
| G-S8 | Weekly drift check of org/repo settings against `fleet/repos.json`, alert on drift | `fleet-drift.yml` runs | Partial (live; needs `FLEET_DRIFT_TOKEN`) |
| G-S9 | Organisation requires 2FA | org settings | Done |

### 4.2 CI execution

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-C1 | Public repos build only on GitHub-hosted runners; `ci.yml` refuses self-hosted for them | `ci.yml` visibility gate; runner groups | Done |
| G-C2 | Private repos build on ephemeral single-job runners; one scale set and namespace per trust domain | ARC config, runner group repo lists | Partial (one shared namespace, task 3.2) |
| G-C3 | Runner pods: no Docker daemon, privileged mode or host mounts; user namespaces; rootless builds | runner pod spec | Done (seccomp/AppArmor unconfined for rootless BuildKit, section 6, task 3.6) |
| G-C4 | Runner network default-deny; egress only DNS + public 443/80 | NetworkPolicy, probe matrix | Done (probe matrix OK 2026-11-09) |
| G-C5 | Every workflow starts with `permissions: {}`; org token read-only; Actions cannot approve PRs | zizmor, org settings | Done |
| G-C6 | No `pull_request_target`/`workflow_run` with untrusted checkout; `persist-credentials: false`; `timeout-minutes` everywhere; no expression injection | zizmor | Done |
| G-C7 | No caches shared across runs or trust domains; fresh BuildKit state per build | workflow review | Done |

### 4.3 Build and gates

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-B1 | One required check `security-gate` aggregating workflow lint + security, secrets, SAST, Trivy, hadolint (checks: [README](../README.md#what-each-run-guarantees)) | `ci.yml` | Done (v3.1.0) |
| G-B2 | Fixable HIGH/CRITICAL blocks, unfixable reported; licence deny-list (AGPL/GPL-3/SSPL) blocks | job summaries | Done (v3.2.0, D-42) |
| G-B3 | Public PRs: dependency review blocks new high-severity dependencies | `ci.yml` | Done (v3.1.0) |
| G-B4 | Lockfiles with hashes, base images by digest (Renovate), OS updates at build | Dockerfiles, Renovate | Partial (per repo) |
| G-B5 | Renovate: 7-day cooldown, 0 days for security fixes, grouped digest bumps for image + policy, registry prefix kept | `renovate/default.json` | Done (#41) |

### 4.4 Artifacts and evidence

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-A1 | Every image signed keyless by digest in a separate GitHub-hosted job; logged in Rekor | `cosign verify` | Done |
| G-A2 | CycloneDX SBOM of the exact scanned image, attested | `cosign verify-attestation --type cyclonedx` | Done |
| G-A3 | SLSA v1 provenance from the sign job (OIDC claims + digest); GitHub artifact attestations for public repos in v4.0.0 | [provenance.md](provenance.md) | Done (v3.1.0; attestations: v4.0.0) |
| G-A4 | Vulnerability scan attested (`cosign-vuln`) for every release | `cosign verify-attestation --type vuln` | Done (v3.1.0) |
| G-A5 | SBOMs re-evaluated continuously (Dependency-Track), EPSS visible | DT project per image | Done (reporting only) |
| G-A6 | **SLSA Build L3**: provenance from an isolated generator the build cannot influence | n/a | Planned (stretch) |
| G-A7 | Reproducible builds (`SOURCE_DATE_EPOCH`, pinned inputs) | rebuild + diff | Planned (stretch) |

### 4.5 Deploy contract

A runtime may run an own image only if **all** of these hold; otherwise it refuses (P1):

1. Signature: keyless, issuer `https://token.actions.githubusercontent.com`, subject
   `https://github.com/Pascal-Organisation/security-pipeline/.github/workflows/build-container.yml@<40-hex SHA>`.
2. Provenance attestation: `externalParameters.workflow.repository` = the app's repo, `ref` = `refs/heads/main`;
   from v3.1.0 also `builder.id` = the reusable workflow at a pinned SHA, and event `push`.
3. CycloneDX SBOM attestation present.
4. From v3.1.0 plus policy rollout: vulnerability attestation present.
5. Third-party images: exact digest listed in git; nothing else.
6. Images referenced by digest; tags are informational.

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-D1 | Items 1-3, 5, 6 enforced at admission, fail-closed, no match = deny | ClusterImagePolicies | Done |
| G-D2 | Item 2 (builder.id, event) and item 4 enforced | ClusterImagePolicies | Done (app cluster, 2026-11-09) |
| G-D3 | Pull-based deploys; CI never holds runtime credentials | updater design | Done |
| G-D4 | Runtime manifests reconciled from git (GitOps) | n/a | Planned (stretch) |

### 4.6 Vulnerability and exception management

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-V1 | Remediation SLAs: Critical 7 d, High 30 d, Medium 90 d | [decisions.md](decisions.md) (D-36) | Done |
| G-V2 | Exceptions only in `.security/exceptions.json` (`id`, `kind`, `reason`, `owner`, `expires`); expired ones reported | `ci.yml` | Done (v3.1.0; owner warns, required in v4.0.0) |
| G-V3 | Not-affected findings as OpenVEX, applied to all scans | `.security/vex.openvex.json` | Done (v3.1.0) |
| G-V4 | Running images re-scanned weekly | in-cluster job | Planned (task 6.3) |

### 4.7 Release and operations

| ID | Goal | Verify | Status |
|---|---|---|---|
| G-R1 | Release order: merge, signed tag, (policy change if needed), caller pin bumps; any SHA of `build-container.yml` is trusted, so no policy edit per release | [release.md](release.md) | Done |
| G-R2 | Toolbox image private, digest-pinned, rebuilt and signed by `toolbox.yml` | GHCR | Done |
| G-R3 | OpenSSF Scorecard weekly, public | `scorecard.yml` | Done |
| G-R4 | Security-relevant org settings declared in `fleet/repos.json` | `fleet-drift.yml` | Done |

## 5. Invariants

Never: run public-repo code on own hardware; sign, attest or push from a job that runs repo code with the signing
identity; trust a tag, registry or network location instead of the signer identity; pin by mutable tag; add a scanner,
threshold or exception in a caller repo; store a long-lived credential where an OIDC token works; disable a gate to
ship (use a time-limited, owned exception).

## 6. Accepted risks and non-goals

| Item | Why accepted | Compensating control | Revisit |
|---|---|---|---|
| 0 required approvals | Single maintainer; no self-approval | Rulesets, signed commits, CODEOWNERS, release policy | Second maintainer or review bot |
| Private repos without CodeQL, GitHub secret scanning, artifact attestations | Paid features | Semgrep, Bandit, TruffleHog, cosign attestations | If plans change |
| Rootless BuildKit needs unconfined seccomp/AppArmor | No free sandbox works on the CI hardware (nested Kata failed) | Ephemeral pod, user namespaces, no privileges, network policy, separate cluster | Task 3.6 |
| SLSA L1+ (not L2/L3) for private repos | Platform provenance needs Enterprise | Provenance from OIDC claims in a separate sign job | L3 milestone |
| Dependency-Track reporting only | Build gate is Trivy | SLAs, weekly re-scan | n/a |

## 7. Maturity levels

Status as of v3.3.0 (see `VERSION`, [decisions.md](decisions.md), tags v3.0.2 to v3.3.0).

| Level | Meaning | Status |
|---|---|---|
| **L1 Baseline** | Signed images, SBOM, fail-closed admission, pinned actions, gates | Reached (v3.0.x, 2026-11-04) |
| **L2 Hardened** | Provenance from the sign job, vulnerability attestation enforced at admission, allowlist + SHA enforcement, CODEOWNERS everywhere, drift check live, runner network isolation, namespace per trust domain | Nearly reached: all met (G-A3, G-A4, G-D2, G-S4, G-S2, G-C4) except namespace per trust domain (G-C2, Partial) and a working drift check (G-S8, Partial) |
| **L3 Verified** | Isolated provenance generator (SLSA Build L3), GitOps with signed commits, reproducible builds, weekly runtime re-scan, failing licence gate | Licence gate failing: done (v3.2.0, D-42). Open: G-A6, G-D4, G-A7, G-V4 |

## 8. KPIs

| KPI | Target |
|---|---|
| Own images running that pass the full deploy contract | 100 % |
| Actions/images referenced by mutable tag | 0 |
| Open fixable Critical/High past SLA | 0 |
| Expired exceptions | 0 |
| `fleet-drift.yml` | green every week |
| OpenSSF Scorecard (this repo) | >= 8.0 |
| Security fix available to released image | within SLA; Renovate security PRs merged within 48 h |

## 9. Governance

- **Change control:** a PR touching workflows, policies, `renovate/` or `fleet/` names the goal IDs it affects.
  Moving away from a goal needs a decision `D-<n>` referencing the goal ID.
- **Drift:** `fleet-drift.yml` weekly; the infrastructure repository checks live vs git for the runtime.
- **Re-audit:** quarterly, compare the goal tables with live state (read-only), update statuses.
- **This document:** status changes go in the PR that delivers them; goal changes need a decision.
