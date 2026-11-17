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
