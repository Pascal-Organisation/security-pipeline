# security-pipeline

Reusable GitHub Actions workflows (security gate, signed container release, DAST, static deploy) for the
Pascal-Organisation repositories. Callers pin a release commit; tools and policy live only here.

Architectural goal: [`docs/target-architecture.md`](docs/target-architecture.md) — principles, goal states, deploy contract, maturity levels.
Current release: see [`VERSION`](VERSION). Fleet: [`fleet/repos.json`](fleet/repos.json), live state via
`tools/fleet-status.sh`. Vulnerability reports: [SECURITY.md](SECURITY.md).

## Workflows

| File | Purpose | Trigger | Key inputs | Secrets |
|---|---|---|---|---|
| `ci.yml` | Security gate; one required check `Security / security-gate` | `workflow_call` | `runner`, `sast-languages`, `python-paths`, `dockerfile`, `scan-skip-dirs` | none |
| `build-container.yml` | Release policy, gate, build (untrusted), scan, SBOM, push (trusted), sign | `workflow_call` (push to `main`) | `runner`, `context`, `dockerfile`, `target`, `submodules` + the `ci.yml` inputs; outputs `image`, `digest` | optional `DTRACK_API_KEY`, `DTRACK_ACCESS_CLIENT_ID`, `DTRACK_ACCESS_CLIENT_SECRET` |
| `deploy-static.yml` | Ship a `.tgz` artifact over `ssh` or `ftps`; never deletes; private repos only | `workflow_call` | `transport` (required), `artifact-file`, `required-file`, `ftps-remote-dir`, `environment`, `url`, `deploy-runner` (default `["self-hosted","deploy"]`) | `ftp-host`, `ftp-user`, `ftp-pass` (ftps); `deploy-ssh-key`, `deploy-known-hosts` (ssh); `ntfy-url` |
| `dast.yml` | ZAP baseline + Nuclei against a public URL; GitHub-hosted | `workflow_call` | `url` (required), `zap-minutes` (default 2) | none |
| `toolbox.yml` | Build, scan, sign the `ci-toolbox` image | PR/push on `toolbox/**` | none | none |
| `self-check.yml` | Runs `ci.yml` on this repo, shellcheck of `tools/*.sh`, VERSION/manifest consistency | PR, push `main`, tags `v*`, weekly | none | none |
| `scorecard.yml` | OpenSSF Scorecard, SARIF to code scanning | push `main`, weekly | none | none |

`private-runner` is a deprecated input, accepted and ignored.

## What each run guarantees

`ci.yml` jobs (all feed `security-gate`; the gate fails if any needed job fails):

| Check | Tool | Blocks on | Runs for |
|---|---|---|---|
| Workflow lint | actionlint | any error | all |
| Workflow security | zizmor | >= medium | all |
| Secrets | TruffleHog (diff on PR/push, full history on schedule) | verified + unknown | all |
| SAST | CodeQL (`security-extended`) | alerts only | public |
| SAST | Semgrep `p/default` | severity ERROR | private |
| SAST (Python) | Bandit | high severity, confidence >= medium | private, with `python-paths` |
| Dependencies and IaC | Trivy fs | fixable HIGH/CRITICAL (vuln, misconfig) | all |
| Dockerfile lint | hadolint | error | all, with `dockerfile` |

Trial jobs `Shell lint (trial)` and `Runtime images (trial)` report only and are not part of the gate.

`build-container.yml`, in order:

1. **Release policy:** ref is `refs/heads/main`, commit is GitHub-verified (signed), commit is the merge result of a PR into `main`.
2. **Gate:** `ci.yml`.
3. **Build** to an OCI tar (private: rootless BuildKit in the CI cluster; public: buildx on GitHub-hosted). This is the only job that runs repo code; it has a read-only token and hands the tar to the next job as a workflow artifact.
3a. **Publish** (GitHub-hosted, no repo code): re-computes the manifest and blob digests of the tar itself, then steps 4 to 7.
4. **Trivy image** on the tar: fixable HIGH/CRITICAL and secrets block.
5. **SBOM:** Syft CycloneDX from the tar; CPEs of `pkg:deb`/`pkg:apk` components are stripped.
6. **Push** the scanned tar to `ghcr.io/pascal-organisation/<repo>` with crane; fails if the registry digest differs from the tar's manifest digest.
7. **Vulnerability evidence:** Trivy JSON (cosign `vuln` format) of the scanned image, passed to the sign job as evidence.
8. **Sign:** in a GitHub-hosted job that runs no repo code and no scanner: SLSA v1 provenance generated there from OIDC claims + digest, keyless Cosign signature, SBOM, provenance and vulnerability attestations; GitHub artifact attestations for public repos are deferred to v4.0.0 (they need `attestations: write` from every caller; details: `docs/provenance.md`).
9. **Dependency-Track:** SBOM upload, reporting only; skipped without the `DTRACK_*` secrets.

Cluster admission (Sigstore policy-controller, `ClusterImagePolicy` per app) accepts an image only with the
signature identity `build-container.yml` of this repo, a CycloneDX attestation and a provenance naming the
repository and `refs/heads/main`.

Exceptions: `.security/exceptions.json` with `id`, `reason`, `owner` (required since v3.1.0: who revisits it),
`expires` (YYYY-MM-DD), optional `kind` (`vulnerability` default, `misconfiguration`, `secret`, `license`).
After expiry the finding blocks again. The non-blocking job `Exceptions expiry (report)` lists expired entries
and those expiring within 14 days as warnings and in the job summary.

Added in v3.1.0 (`ci.yml`):

- **zizmor online audits** on public repos (GitHub-hosted, read-only `GITHUB_TOKEN`): impostor commits, known-vulnerable actions, ref confusion. The offline run stays everywhere.
- **Licence gate:** inputs `license-gate` (`off` | `warn` | `fail`, default `fail` since v3.2.0) and `license-deny` (default `AGPL-3.0*,GPL-3.0*,SSPL-1.0`). `warn` lists violations without failing; **the default becomes `fail` in the next release**. Exceptions: `kind: "license"`, `id` = licence name or package name.
- **Dependency review** (`actions/dependency-review-action`, fail on high) on pull requests of public repos; part of `security-gate`.
- **VEX:** an optional `.security/vex.openvex.json` is passed to Trivy `--vex` (repo scan and image scan).
- **Trivy SARIF** (HIGH/CRITICAL) uploaded to code scanning on public repos (not for fork PRs; never blocks).

## Calling the workflows

```yaml
jobs:
  security:
    name: Security          # the caller job must be named Security
    uses: Pascal-Organisation/security-pipeline/.github/workflows/ci.yml@<full-sha> # vX.Y.Z
    permissions:            # upper bound; must also cover skipped nested jobs, else startup_failure
      contents: read
      actions: read
      security-events: write
      packages: read
    with:
      dockerfile: Dockerfile
```

`build-container.yml` callers grant `contents: read`, `actions: read`, `security-events: write`,
`pull-requests: read`, `packages: write`, `id-token: write`. Pass the three `DTRACK_*` secrets explicitly,
not `secrets: inherit`. Full caller examples: [docs/new-project.md](docs/new-project.md).

Contract with callers (changing it is a major release): check name `Security / security-gate`, the input
names above, the workflow path `build-container.yml` (it is the signing identity), `.security/exceptions.json`.

## Versioning and pinning

- Callers pin the full commit SHA with a `# vX.Y.Z` comment; Renovate bumps it via the shared preset.
- Preset: `local>Pascal-Organisation/security-pipeline//renovate/default` (digest pins, weekly lock-file maintenance, automerge of aged minor/patch, majors and runtime-image minors by hand).
- Rings: `canary` (`workingrepo`, `anmeldungunihandball`) takes a release at once; `stable` after `minimumReleaseAge` (3 days). Majors are manual.
- Release steps: [docs/release.md](docs/release.md).

## Runners

| Repo visibility | Runs on |
|---|---|
| Public | GitHub-hosted only; visibility is read from the API, never from an input |
| Private | Self-hosted ARC scale sets (input `runner`, default `arc-ci`), one fresh pod per job |

Signing, DAST and the FTPS upload always run GitHub-hosted. Details: [docs/runners.md](docs/runners.md).

## Other docs

| Doc | Content |
|---|---|
| [docs/target-architecture.md](docs/target-architecture.md) | Architectural goal: principles, goal IDs with status, deploy contract, maturity levels |
| [docs/provenance.md](docs/provenance.md) | What the provenance and attestations contain, and the honest SLSA level |
| [docs/new-project.md](docs/new-project.md) | Create and register a new repository |
| [docs/release.md](docs/release.md) | Releasing the pipeline |
| [docs/runners.md](docs/runners.md) | Runner groups and isolation rules |
| [docs/switching-tools.md](docs/switching-tools.md) | Replacing a tool, `bk` |
| [docs/decisions.md](docs/decisions.md) | One line per design decision |

Local checks: copy `templates/pre-commit-config.yaml` to `.pre-commit-config.yaml`; sign commits
(`gpg.format ssh`, `commit.gpgsign true`).
