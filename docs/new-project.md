# New project

## Flow

```bash
gh repo create Pascal-Organisation/<name> --template Pascal-Organisation/app-template --private --clone
```

The template (`container-pull` profile) contains: `Dockerfile` (digest-pinned base, non-root user, `runtime` stage), `www/` placeholder app, `.github/workflows/ci.yml` (calls `ci.yml`, job `Security`) and `release.yml` (calls `build-container.yml`, `target: runtime`), `renovate.json` (shared preset), `.pre-commit-config.yaml`, `SECURITY.md`. Pins are full SHAs with a `# vX.Y.Z` comment.

1. In the clone: replace every `CHANGEME`, the placeholder app in `www/` and `Dockerfile`, and the README text.
2. Workflow inputs: `sast-languages` (public only), `python-paths` (private only), `runner: arc-<name>` (private repo with its own scale set; default `arc-ci`). Keep `sast-languages` identical in `ci.yml` and `release.yml`.
3. Register the repo (PR to this repo) in `fleet/repos.json`:

   ```json
   { "name": "<name>", "profile": "container-pull", "ring": "stable", "gate_check": "Security / security-gate" }
   ```

   Profiles: `ci-only`, `container-pull`, `static-ftps`. `ring` is `canary` or `stable`; `canary` must match the repos in `renovate/default.json`. Optional: `extra_required_checks`, `rulesets: false`, `note`.
4. Rulesets: `tools/fleet-rulesets.sh` (dry run), then `tools/fleet-rulesets.sh --apply`. Creates the `protect main` ruleset requiring `gate_check` (plus `extra_required_checks`) from the GitHub Actions app. Private repos on GitHub Free answer 403 and are reported, not protected.
5. Verify: PR shows green `Security / security-gate`; first merge to `main` completes `build-container.yml`; `tools/fleet-status.sh` lists the repo and its pin.

## Public repositories, extra steps

| Step | Where |
|---|---|
| Add the repo to *Packages, ci-toolbox, Package settings, Manage Actions access* with role **Read** (UI only; without it the toolbox pull fails with `unauthorized`) | `https://github.com/orgs/Pascal-Organisation/packages/container/ci-toolbox/settings` |
| After the first release, make the GHCR package `<name>` public (otherwise the cluster gets `ImagePullBackOff`) | package settings |
| Keep `SECURITY.md` | repo root |

Private repos: the cluster pulls with its own pull secret; the GHCR package stays private.

## Other profiles

- `ci-only`: only the `ci.yml` caller.
- `static-ftps` (private repos): own build job uploads artifact `site` (`site.tgz`), then `deploy-static.yml` with secrets `ftp-host`, `ftp-user`, `ftp-pass`; `dast.yml` before (staging) or after the deploy.

## Rules

- The caller job in `ci.yml` is named `Security`, otherwise the required check does not match.
- Do not add Dependabot. Trivy only sees dependencies through lock/requirements files.
- Renaming or moving a repo changes the image path and signing identity; the cluster policy must follow.

Cluster side: see the new-app guide in the private infrastructure repository.
