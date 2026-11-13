# Decisions

One line per active decision. Retired: D-13, D-14, D-29 (superseded or removed). The number D-9 was given twice (provenance in the sign job; the gate runs once per release); both lines stay valid and no other document cites D-9.

| ID | Decision |
|---|---|
| D-1 | One central reusable pipeline with a small, stable contract |
| D-2 | Keyless signing in a separate GitHub-hosted job |
| D-3 | One release workflow carries policy, gate, build and signature |
| D-4 | Release only from a signed merge commit of a PR on `main` |
| D-5 | Cluster trusts any SHA of `build-container.yml` (identity regex); provenance must name the caller repo and `refs/heads/main`. Replaced the release-commit allowlist, 2026-11-05 |
| D-6 | Signed SBOM and provenance, described honestly as SLSA L1 + signature |
| D-9 | Provenance is generated in the sign job from OIDC claims + digest; vuln attestation (Trivy JSON) added; GitHub build provenance for public repos is deferred (D-41). Still L1 + signature, see [provenance.md](provenance.md) |
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
| D-33 | Licence deny-list gate, `warn` in v3.1.0; exceptions need an `owner`. Superseded by D-42 (default `fail`) |
| D-34 | zizmor online audits on public repos only (read-only token); dependency-review on public PRs |
| D-35 | Optional OpenVEX file `.security/vex.openvex.json` feeds Trivy; Trivy SARIF goes to code scanning for public repos only |
| D-36 | Remediation SLAs: Critical 7 d, High 30 d, Medium 90 d |
| D-37 | Weekly drift check of org Actions settings, rulesets and code security against `fleet/repos.json`, read-only token, ntfy on drift |
| D-38 | Public rulesets: signed commits, stale reviews dismissed, threads resolved, strict checks; 0 required approvals, since a review count would block the only maintainer |
| D-39 | Org Actions allowlist (`selected`, SHA pinning required, fork-PR approval for all external contributors on public repos) |
| D-40 | [target-architecture.md](target-architecture.md) is the binding goal (P1-P10, goal IDs, deploy contract, maturity L1-L3). Moving away from a goal needs a decision naming its ID |
| D-41 | v3.1.0 is a minor release: `owner` on exceptions warns in v3.x and is required in v4.0.0 (caller contract change, [release.md](release.md)); `actions/attest-build-provenance` (needs caller `attestations: write`) moves to v4.0.0 |
| D-42 | v3.2.0: licence gate default `fail` (deny-list AGPL-3.0*/GPL-3.0*/SSPL-1.0, exceptions with `kind: license`); no caller had findings on v3.1.x (checked 2026-11-09) |
| D-43 | The build job holds no registry write permission; a separate GitHub-hosted `publish` job re-hashes the OCI tar, scans, pushes and reports the digest (G-A6 step, G-A3, P5). No caller-visible change |
| D-44 | v3.3.0 is an unsigned lightweight tag on the verified merge commit `38ca59d`: the Release was created before the signed tag was pushed. Accepted, because the tag ruleset forbids replacing it, callers pin the SHA and consumers trust the workflow identity, not the tag. G-S3 stays Partial; [release.md](release.md) requires `--verify-tag` and a tag-type check |
| D-45 | 2026-11-13, after a read-only review of the pipeline against SLSA, OpenSSF Scorecard and the CIS supply chain benchmark: (1) **Builder commits are pinned again.** Deploy contract item 1 names the commit of a signed release tag instead of any 40-hex SHA; this supersedes D-5 once the consumer generates its list from the tags without a hand edit (the reason for D-5 was the policy change per release). Reason: any commit on any branch of this repository, also an unmerged one, satisfied the signer pattern (G-D1, G-R1, new G-S10). (2) **SLSA Build L2 for public repos is a goal** (G-A8, with v4.0.0); private repos stay at L1 plus signature. (3) **Scorecard KPI is 7.5**, not 8.0, with per-check targets (section 8). (4) New goals G-S11 (app permissions), G-B6 (code scanning gate, pinned Semgrep rules), G-V5 (KEV/EPSS), G-R5 (callers current, dead references reported), G-R6 (scheduled scans not cancellable); G-V2 and G-R2 restated (90-day exceptions, toolbox freshness). (5) Maturity levels carry no dates; the order of work is in the operator's private roadmap |
