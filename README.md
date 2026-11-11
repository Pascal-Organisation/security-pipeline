# security-pipeline

Reusable GitHub Actions workflows (security gate, signed container release, DAST, static deploy) for the
Pascal-Organisation repositories. Callers pin a release commit; tools and policy live only here.

Current release: [`VERSION`](VERSION). Fleet: [`fleet/repos.json`](fleet/repos.json), live state via
`tools/fleet-status.sh`. Goal and principles: [`docs/target-architecture.md`](docs/target-architecture.md).
Vulnerability reports: [SECURITY.md](SECURITY.md).

## Workflows

| File | Purpose | Trigger | Key inputs | Secrets |
|---|---|---|---|---|
| `ci.yml` | Security gate; one required check `Security / security-gate` | `workflow_call` | `runner`, `sast-languages`, `python-paths`, `dockerfile`, `scan-skip-dirs`, `license-gate`, `license-deny`; output `private` | none |
| `build-container.yml` | Release policy, gate, build (untrusted), scan, SBOM, push (trusted), sign | `workflow_call` (push to `main`) | `runner`, `context`, `dockerfile`, `target`, `submodules`, and the gate inputs `sast-languages`, `python-paths`, `scan-skip-dirs` (`license-gate` and `license-deny` are not forwarded: the release gate always uses their defaults); outputs `image`, `digest` | optional `DTRACK_API_KEY`, `DTRACK_ACCESS_CLIENT_ID`, `DTRACK_ACCESS_CLIENT_SECRET` |
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
| SAST | CodeQL (`security-extended`) | nothing: alerts go to code scanning, the job does not fail on them | public |
| SAST | Semgrep `p/default` | severity ERROR | private |
| SAST (Python) | Bandit | high severity, confidence >= medium | private, with `python-paths` |
| Dependencies and IaC | Trivy fs | fixable HIGH/CRITICAL (vuln, misconfig) | all |
| Dockerfile lint | hadolint | error | all, with `dockerfile` |

Trial jobs `Shell lint (trial)` and `Runtime images (trial)` only report.

`build-container.yml`, in order:

1. **Release policy:** ref is `refs/heads/main`; commit is GitHub-verified and the merge result of a PR into `main`.
2. **Gate:** `ci.yml`.
3. **Build** to an OCI tar (private: rootless BuildKit in the CI cluster; public: buildx on GitHub-hosted). The only job that runs repo code; read-only token.
4. **Publish** (GitHub-hosted, no repo code): re-computes the tar's digests, then scans it with Trivy (fixable HIGH/CRITICAL and secrets block), creates the Syft CycloneDX SBOM (CPEs of `pkg:deb`/`pkg:apk`/`pkg:rpm` stripped), pushes it with crane to `ghcr.io/pascal-organisation/<repo>` (fails if the registry digest differs from the tar's) and produces Trivy JSON as vulnerability evidence.
5. **Sign** (GitHub-hosted, no repo code, no scanner): SLSA v1 provenance from OIDC claims + digest, keyless Cosign signature, SBOM, provenance and vulnerability attestations. GitHub artifact attestations for public repos wait for v4.0.0 ([docs/provenance.md](docs/provenance.md)).
6. **Dependency-Track:** SBOM upload, reporting only; skipped without the `DTRACK_*` secrets.

Cluster admission (Sigstore policy-controller, `ClusterImagePolicy` per app) accepts an image only with the
signature identity `build-container.yml` of this repo, a CycloneDX attestation and a provenance naming the
repository and `refs/heads/main` (full contract: [target-architecture.md](docs/target-architecture.md)).

Exceptions: `.security/exceptions.json` with `id`, `reason`, `owner` (who revisits it; warns in v3.x, required in v4.0.0),
`expires` (YYYY-MM-DD), optional `kind` (`vulnerability` default, `misconfiguration`, `secret`, `license`).
After expiry the finding blocks again. The non-blocking job `Exceptions expiry (report)` warns about expired entries
and those expiring within 14 days.

Further `ci.yml` checks:

- **zizmor online audits** on public repos (read-only `GITHUB_TOKEN`): impostor commits, known-vulnerable actions, ref confusion.
- **Licence gate:** inputs `license-gate` (`off` | `warn` | `fail`, default `fail`) and `license-deny` (default `AGPL-3.0*,GPL-3.0*,SSPL-1.0`). Exceptions: `kind: "license"`, `id` = licence or package name.
- **Dependency review** (`actions/dependency-review-action`, fail on high) on public-repo PRs; part of `security-gate`.
- **VEX:** an optional `.security/vex.openvex.json` is passed to Trivy `--vex`.
- **Trivy SARIF** (HIGH/CRITICAL) goes to code scanning on public repos (not fork PRs; never blocks).

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

- Callers pin the full commit SHA with a `# vX.Y.Z` comment; Renovate bumps it.
- Preset: `local>Pascal-Organisation/security-pipeline//renovate/default` (digest pins, weekly lock-file maintenance, automerge of aged minor/patch; majors and runtime-image minors by hand).
- Rings: `canary` (`workingrepo`, `anmeldungunihandball`) takes a release at once; `stable` after `minimumReleaseAge` (3 days).
- Releasing: [docs/release.md](docs/release.md).

## Runners

| Repo visibility | Runs on |
|---|---|
| Public | GitHub-hosted only; visibility is read from the API, never from an input |
| Private | Self-hosted ARC scale sets (input `runner`, default `arc-ci`), one fresh pod per job |

Publish (scan, SBOM, push), signing, DAST and the FTPS upload always run GitHub-hosted. See [docs/runners.md](docs/runners.md).

## Other docs

| Doc | Content |
|---|---|
| [target-architecture.md](docs/target-architecture.md) | Principles, goal IDs with status, deploy contract, maturity levels |
| [provenance.md](docs/provenance.md) | Provenance and attestations; the SLSA level |
| [new-project.md](docs/new-project.md) | Create and register a repository |
| [release.md](docs/release.md) | Release the pipeline |
| [runners.md](docs/runners.md) | Runner groups and isolation |
| [switching-tools.md](docs/switching-tools.md) | Replace a tool; `bk` |
| [decisions.md](docs/decisions.md) | One line per decision |

Local checks: copy `templates/pre-commit-config.yaml` to `.pre-commit-config.yaml` and sign commits
(`gpg.format ssh`, `commit.gpgsign true`).
