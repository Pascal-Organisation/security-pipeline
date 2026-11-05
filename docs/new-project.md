# Connecting a new project to the pipeline

A new repository needs only a few lines: it calls the workflows here and registers itself in
`fleet/repos.json`. Tools and rules stay in this repository.

## 1. Pick a profile

| The project is … | Profile | Workflows | Template |
|---|---|---|---|
| code or scripts only | `ci-only` | `ci` | `homelab`, `anmeldungunihandball` |
| runs in the app cluster, including a static site | `container-pull` | `ci`, `build-container` | `solar` (public), `bahnbot` (private) |
| shared hosting that checks nothing itself, private | `static-ftps` | `ci`, `deploy-static`, `dast` | `websiteghana` |

The pipeline decides by visibility on its own:

| | Public | Private |
|---|---|---|
| Runner | GitHub-hosted, always | CI cluster, a fresh pod per job; one scale set per trust domain |
| SAST | CodeQL (`sast-languages`) | Semgrep, plus Bandit with `python-paths` |
| Signature | keyless | keyless; the repo name appears in the public Rekor log |

A private repository that ships something gets its own scale set and runner group (`arc-<repo>`). Repos
that only run CI share `arc-ci`. See the homelab repository for how to add a scale set.

## 2. Create the repository

- Create it in the org, with default branch `main`.
- `renovate.json`:

  ```json
  {
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["local>Pascal-Organisation/security-pipeline//renovate/default"]
  }
  ```

- Do **not** set up Dependabot as well (leave out `.github/dependabot.yml`).
- Copy `templates/pre-commit-config.yaml` as `.pre-commit-config.yaml`.
- Public repository: add a `SECURITY.md`.

## 3. Add the CI gate

Get the commit of the latest release:

```bash
gh api repos/Pascal-Organisation/security-pipeline/commits/$(cat VERSION) --jq .sha
```

`.github/workflows/ci.yml`, suitable for every profile:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "41 4 * * 1" # weekly: full history for secrets, fresh CVE data
  workflow_dispatch:

permissions: {}

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  security:
    name: Security # required: produces the check "Security / security-gate"
    uses: Pascal-Organisation/security-pipeline/.github/workflows/ci.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      actions: read
      security-events: write
      packages: read                         # required since v3: GitHub-hosted pulls the private ci-toolbox
    with:
      sast-languages: python,actions         # effective for public repos only
      python-paths: src                      # effective for private repos only
      dockerfile: Dockerfile                 # omit if there is none
      # runner: arc-<repo>                   # private repos with their own scale set
```

The `permissions` are an upper bound, and they must also cover skipped jobs. The pin with a version comment
matters, because that's how Renovate recognises the version.

**The private toolbox.** The `ci-toolbox` package is private, so callers must grant `packages: read`.
Without it the `GITHUB_TOKEN` can't pull, and jobs fail with `unauthorized`.

Additionally, **every public caller** (it runs GitHub-hosted) must be added once under **Manage Actions
access** with role **Read**, at
`https://github.com/orgs/Pascal-Organisation/packages/container/ci-toolbox/settings`. This is UI-only, not
possible via the API.

Private repos run in the CI cluster and don't need that: the cluster pulls with the `ghcr-pull` secret.
The login happens only on GitHub-hosted runners, in a throwaway `DOCKER_CONFIG` that is deleted right after
the pull.

Trivy sees dependencies **only through lock files or requirements files**. Without one it is blind, even if
the gate is green.

## 4. Add the profile part

It's easiest to copy from the template in the table.

### Container (`container-pull`)

`release.yml` as in `solar`: on push to `main`, call `build-container`. The gate runs inside it, so don't
call it separately.

Permissions for the job that calls `build-container`:
- `contents: read`, `actions: read`, `security-events: write`;
- `pull-requests: read`, `packages: write`, `id-token: write`.

If the release workflow also calls the repo's own `ci.yml` (for tests), that job needs `packages: read`
too. Otherwise the run ends in **`startup_failure`**, because a nested job asks for more than its caller
grants.

In the app cluster (homelab repository, `Homelab-Skripte/k3s-apps/`):

- Add Deployment and Service as a manifest. Secrets live in the cluster.
- Add a `ClusterImagePolicy` for `ghcr.io/pascal-organisation/<repo>`. It demands the signature of
  `build-container.yml@<sha>` (release commits of the pipeline, GitHub OIDC issuer, repository,
  `refs/heads/main`) and the attestations. Without a matching policy the pod does not start.
- Add an updater CronJob, if new builds should roll out by themselves.
- The cluster needs read access to the image:
  - **public repos** make the package public after the first release;
  - **private repos** get a pull secret in the namespace.
  - Without it the cluster reports `ImagePullBackOff` while the release pipeline stays green.

### Shared hosting (`static-ftps`)

- Your own build job uploads the artifact `site` with the file `site.tgz`.
- Secrets `FTP_HOST`, `FTP_USER`, `FTP_PASS`. Nothing is ever deleted.
- Call `dast.yml` after the deploy (or before it, against staging), and only against your own sites.

## Rule: no deployment without a green gate

This holds for every deploying repository, private ones included. GitHub Free can't block a merge in a
private repository, but the pipeline can block the release:

- **`container-pull`:** the gate runs inside `build-container.yml`, and cluster admission accepts only that
  workflow's signature. A repository can't get around this, not even by editing its own workflow.
- **`static-ftps`:** `deploy-static.yml` checks the gate and `main` itself before uploading. The target
  checks nothing, so this check is the only protection, and anyone who edits the workflow in the repo can
  get past it. That is stated openly.

## 5. Register in the fleet

Add it to `fleet/repos.json` via PR:

```json
{ "name": "my-project", "profile": "ci-only", "ring": "stable", "gate_check": "Security / security-gate" }
```

Note deviations from the standard with `"note"`. `canary` is reserved for the two repositories named in
`renovate/default.json`.

## 6. Verify and switch on

1. PR in the new repository: `Security / security-gate` must be green.
2. Wait for the first release: policy, gate, build and signature must be green.
3. `tools/fleet-status.sh` shows the repository with its current pin.
4. Public repository: run `tools/fleet-rulesets.sh`, read the output, then `--apply`. Private repos can't be
   protected on GitHub Free; there the gate only reports.
5. Container: check in the cluster that the pod runs the new digest. Green in GitHub doesn't mean it has
   arrived.

## Pitfalls

- **Renaming or moving a repository** changes the image path and the signing identity. The
  `ClusterImagePolicy` has to move too. Otherwise admission rejects the new image, or the cluster stays on
  the old version.
- **The caller job must be named `Security`**, or the required check doesn't match.
- **Don't depend on tool names**, neither in workflows nor in rulesets, only on `security-gate`. Otherwise
  the next tool swap breaks the repository ([switching-tools.md](switching-tools.md)).
- **Exceptions** only through `.security/exceptions.json`, always with a reason and an expiry date.
- **Your own tests** belong in the repository as separate jobs. The security gates don't.
- **Your own Dockerfile tests** in a private repo: there is no Docker daemon on the CI cluster. Use `bk` from
  the toolbox (see [switching-tools.md](switching-tools.md#building-images-bk)).
