# Decisions

One line per active decision. Retired: D-13, D-14, D-29 (superseded or removed).

| ID | Decision |
|---|---|
| D-1 | One central reusable pipeline with a small, stable contract |
| D-2 | Keyless signing in a separate GitHub-hosted job |
| D-3 | One release workflow carries policy, gate, build and signature |
| D-4 | Release only from a signed merge commit of a PR on `main` |
| D-5 | Cluster trusts any commit SHA of `build-container.yml` (identity regex); provenance must name the caller repo + `refs/heads/main` (replaced the release-commit allowlist, 2026-11-05) |
| D-6 | Signed SBOM and provenance, described honestly as SLSA L1 + signature |
| D-9 | Provenance is generated in the sign job from OIDC claims + digest (not from a build-job file); vuln attestation (Trivy JSON) added; public repos also get GitHub build provenance. Still honestly L1 + signature, see docs/provenance.md |
| D-7 | Dependency-Track reports, it does not gate |
| D-8 | Strip guessed CPEs from OS packages in the SBOM |
| D-9 | The security gate runs once per release |
| D-10 | Exceptions in one scanner-neutral file, with reason and expiry |
| D-11 | Ruleset on public repositories; private repositories accepted as unprotected |
| D-12 | Public code never runs on our own machines |
| D-15 | Runner pods in their own user namespace, with rootless BuildKit |
| D-16 | One ARC scale set and runner group per trust domain |
| D-17 | GitHub App with exactly one permission for ARC |
| D-18 | A specific sub-ID layout for builds in user-namespaced pods |
| D-19 | No Docker daemon in CI jobs |
| D-20 | One digest-pinned, private toolbox image for every tool |
| D-21 | `bk`: rootless BuildKit with its process sandbox left on |
| D-22 | Scan the tar, push exactly those bytes, require digest equality |
| D-23 | Public images build on GitHub-hosted runners with buildx |
| D-24 | BuildKit cleanup runs in its user namespace and only warns |
| D-25 | Docker stays only where it is the only way |
| D-26 | Deployments are pulled, never pushed into the LAN |
| D-27 | The cluster's admission controller decides what runs |
| D-28 | Third-party images run only by exact digest |
| D-30 | Static FTPS deploy: GitHub-hosted, checks itself, never deletes |
| D-31 | DAST always on GitHub-hosted runners |
| D-32 | Renovate with digest pins, rollout rings and limited automerge |
| D-33 | Licence deny-list gate, `warn` in v3.1.0 and `fail` from the next release; exceptions need an `owner` |
| D-34 | zizmor online audits on public repos only (read-only token); dependency-review on public PRs |
| D-35 | Optional OpenVEX file `.security/vex.openvex.json` feeds Trivy; Trivy SARIF goes to code scanning for public repos only |
| D-36 | Remediation SLAs: Critical 7 d, High 30 d, Medium 90 d |
| D-37 | Weekly drift check of org Actions settings, rulesets and code security against `fleet/repos.json`, read-only token, ntfy on drift |
| D-38 | Public rulesets: signed commits, stale reviews dismissed, threads resolved, strict checks; 0 required approvals (single maintainer; CODEOWNERS documents ownership, review count would block the only maintainer) |
| D-39 | Org Actions allowlist (`selected`, SHA pinning required, fork-PR approval for all external contributors on public repos) |
| D-40 | Adopt [`target-architecture.md`](target-architecture.md) as the binding architectural goal (principles P1–P10, goal IDs, deploy contract, maturity L1–L3). Changes that move away from a goal need a decision naming the goal ID. |
| D-41 | v3.1.0 is a minor release: `owner` on exceptions only warns in v3.x and becomes required in v4.0.0 (caller contract change per `release.md`); licence gate default stays `warn` until v3.2.0; `actions/attest-build-provenance` (needs caller `attestations: write`) moves to v4.0.0 |
| D-42 | v3.2.0: licence gate default `fail` (deny-list AGPL-3.0*/GPL-3.0*/SSPL-1.0, exceptions with `kind: license`). Checked 2026-11-09: no caller had licence findings on v3.1.x |

Full decision rationale: git history of docs/decisions.md before this commit.
