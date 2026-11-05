# Releasing the pipeline

| Step | Action |
|---|---|
| 1 | Set `VERSION` and `PIPELINE_VERSION` (env in `build-container.yml`) to the same `vX.Y.Z`; PR to `main` |
| 2 | Merge the PR (commits must be signed) |
| 3 | Create a signed, annotated tag `vX.Y.Z` on the merge commit: `git tag -s -a vX.Y.Z <sha> -m vX.Y.Z && git push origin vX.Y.Z` |
| 4 | Create a GitHub Release for the tag |
| 5 | Renovate opens bump PRs in the callers: canary ring at once, stable ring after `minimumReleaseAge` (3 days) |

- Tag protection: ruleset `protect release tags` (`refs/tags/v*`: no delete, no force-push, no update), applied by `tools/fleet-rulesets.sh`.
- `self-check.yml` job `Version & manifest consistency` fails if `PIPELINE_VERSION` in `build-container.yml` differs from `VERSION`, if a pushed tag differs from `VERSION`, or if `fleet/repos.json` has an entry without `name`, a `profile` in (`ci-only`, `container-pull`, `static-ftps`), a `ring` in (`canary`, `stable`) or `gate_check`.
- Cluster policies match any SHA of `build-container.yml` of this repo, so a release needs no cluster change.
- Toolbox: `toolbox.yml` builds and signs `ci-toolbox` on `main`; the digest in `TOOLBOX` (`ci.yml`, `build-container.yml`) is bumped by Renovate.
- Caller contract changes (input, secret, check name, workflow path) are a major release; Renovate does not automerge majors.
