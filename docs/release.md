# Releasing the pipeline

| Step | Action |
|---|---|
| 1 | Set `VERSION` and `PIPELINE_VERSION` (env in `build-container.yml`) to the same `vX.Y.Z`; PR to `main` |
| 2 | Merge the PR (commits must be signed) |
| 3 | Create a signed, annotated tag `vX.Y.Z` on the merge commit: `git tag -s -a vX.Y.Z <sha> -m vX.Y.Z && git push origin vX.Y.Z` |
| 4 | Create a GitHub Release for the tag, only after step 3: `gh release create vX.Y.Z --verify-tag --generate-notes` (`--verify-tag` aborts if the tag is not on the remote) |
| 5 | Renovate opens bump PRs in the callers: canary ring at once; stable ring: patch and digest at once, a minor release after `minimumReleaseAge` of 7 days (new functions, D-46) |

- Order matters: creating a Release for a tag that does not exist yet makes GitHub create an unsigned lightweight tag, and the tag ruleset then makes that tag permanent. This happened with v3.3.0 (D-44). Check before announcing a release: `git fetch --tags && git cat-file -t vX.Y.Z` must print `tag`, and `git tag -v vX.Y.Z` must verify.
- Tag protection: ruleset `protect release tags` (`refs/tags/v*`: no delete, no force-push, no update; the live ruleset also requires signatures, a rule `tools/fleet-rulesets.sh` does not set yet), applied by `tools/fleet-rulesets.sh`.
- `self-check.yml` job `Version & manifest consistency` fails if `PIPELINE_VERSION` in `build-container.yml` differs from `VERSION`, if a pushed tag differs from `VERSION`, or if `fleet/repos.json` has an entry without `name`, a `profile` in (`ci-only`, `container-pull`, `static-ftps`), a `ring` in (`canary`, `stable`) or `gate_check`.
- Cluster policies match any SHA of `build-container.yml` of this repo, so a release needs no cluster change.
- Toolbox: `toolbox.yml` builds and signs `ci-toolbox` on `main`; the digest in `TOOLBOX` (`ci.yml`, `build-container.yml`) is bumped by hand after `toolbox.yml` has signed a new image, until an automation exists (Renovate cannot read the private package and the shared preset disables `ghcr.io/pascal-organisation/**`). Verify first: `cosign verify` and `cosign verify-attestation --type cyclonedx` with the identity `^https://github.com/Pascal-Organisation/security-pipeline/.github/workflows/toolbox.yml@refs/heads/main$`.
- Caller contract changes (input, secret, check name, workflow path) are a major release; Renovate does not automerge majors.

## Toolbox pin automation

Job `pin` in `toolbox.yml` (D-49) keeps the `TOOLBOX` pins (`ci.yml`, `build-container.yml`) on the newest signed toolbox. After `build` has pushed and signed on `main`, it verifies signature and SBOM attestation, commits the new digest to `bot/toolbox-pin` (contents API as a GitHub App, so the commit is signed and verified), opens or updates the PR and sets auto-merge (squash); required checks and the ruleset still apply and the PR's CI already runs on the new digest. No change, no PR; missing secrets, only a warning. A merged bump is followed by a patch release by the owner (steps above; the PR body has the commands); tags are never created by the job.

Owner setup, once:

1. github.com/settings/apps/new (or the organisation's Developer settings): name `security-pipeline toolbox-pin`, homepage any URL, Webhook: off. Repository permissions: Contents Read and write, Pull requests Read and write, Workflows Read and write (the pins are in workflow files; without it GitHub rejects the commit), Metadata Read (implied); everything else No access (no Packages). Install on Only select repositories: `security-pipeline`.
2. In the App settings generate a private key (`.pem`) and note the App ID.
3. Repository secrets of `security-pipeline` (Settings > Secrets and variables > Actions): `TOOLBOX_PIN_APP_ID` (the App ID) and `TOOLBOX_PIN_APP_KEY` (whole `.pem` content). Delete the local `.pem` afterwards.
4. "Allow GitHub Actions to create and approve pull requests" is not needed: it applies to `GITHUB_TOKEN` only, and the job uses the App token. Auto-merge is already allowed on the repository.
5. Run `ci-toolbox` once via workflow_dispatch on `main` to test; a PR `bot/toolbox-pin` appears if the pin is behind.

Known limit: with "require branches up to date" a bump PR that falls behind `main` waits until the next toolbox run recreates it or someone updates the branch.
