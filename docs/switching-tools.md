# Swapping tools, releasing the pipeline

The goal: a scanner, a signing method or a rule is swapped **here**. The repositories notice nothing, apart
from a pin update by Renovate.

## The contract (what repositories know about the pipeline)

Repositories may depend on these things only. Changing any of them is a **major release**.

| Contract | Value |
|---|---|
| Required check | `Security / security-gate` (the caller job is named `Security`) |
| `ci.yml` inputs | `runner`, `sast-languages`, `python-paths`, `dockerfile`, `scan-skip-dirs` (`private-runner`: deprecated, ignored) |
| `build-container.yml` | inputs `runner`, `context`, `dockerfile`, `target`, `submodules`, `sast-languages`, `python-paths`, `scan-skip-dirs` (`private-runner`: deprecated, ignored); **the workflow path is the signing identity** |
| Exceptions | `.security/exceptions.json` |

Job names like `SAST (private)` name capabilities, not tools. Nobody should depend on them as a check; only
`security-gate` counts.

## Procedure: replacing a tool

Example: replace Trivy with something else. Since v3 every tool lives in the `ci-toolbox` image
(`toolbox/Dockerfile`):

- A new tool goes in there first, pinned by digest from its official image.
- `toolbox.yml` builds and signs the new toolbox.
- Then the digest in `TOOLBOX` (`ci.yml` and `build-container.yml`) is raised.
- The workflows call it through `tb <tool>`.

1. **Trial:** add a new job to `ci.yml` that only reports and always ends green. Keep it **out of** the
   `needs` of `security-gate`. Don't use `continue-on-error`: the red check would stop Renovate's automerge.
   Release as a minor. The rings roll it out, and nothing blocks.
2. **Compare:** look at both tools' findings for one or two releases. `tools/fleet-status.sh` shows the state.
3. **Switch:** add the new job to `needs`, treat its findings as errors, and delete the old job. Translate
   the exceptions to the new scanner in the same commit. Release as a minor, as long as the contract stays
   the same.

No caller changes. If the contract does break (a new input, a new secret), it's a major, and Renovate does
not merge it by itself.

## Procedure: changing signing or verification

Cluster admission depends on this as well, so do it with an overlap:

1. In the `ClusterImagePolicy` objects, allow both identities. Use one `authorities` entry each, with
   `identities`, issuer GitHub OIDC and `subjectRegExp` on `…/old.yml@<sha>` and `…/new.yml@<sha>`, both
   pinned to release commits.
2. Switch the pipeline, release, and wait for one deployment.
3. Remove the old identity from the policies.

Don't rename or move `build-container.yml` without step 1: the policies allow exactly this path.

## Building images: `bk`

`bk` (in the toolbox, `toolbox/bk` → `/usr/local/bin/bk`) builds **one stage** of a Dockerfile with rootless
BuildKit, without a Docker daemon. Caller repositories don't need their own wrapper:

```sh
bk [<stage>] [-C <context>] [-f <dockerfile>] [--build-arg K=V]... [further buildctl arguments]
```

- **Output:** without `--output` it only builds (as a check) and exports nothing. A failing `RUN` step fails
  the stage. For an image: `--output type=oci,dest=$RUNNER_TEMP/image.tar`.
- **Other arguments:** anything unknown goes to `buildctl build` unchanged (`--opt label:k=v`, `--no-cache`, …).
- **State:** BuildKit state and socket live under `$RUNNER_TEMP` (`--root`, `--otel-socket-path`), fresh per
  job. Base images are always resolved from the registry.
- **BuildKit's process sandbox stays on.** `--oci-worker-no-process-sandbox` is not used. Every `RUN` step
  gets its own PID namespace and a fresh `/proc`, which needs `procMount: Unmasked` in the cluster (pod with
  `hostUsers: false`).
- **Where `bk` works:** it is meant for the **CI cluster**, where it runs directly (`bk runtime …`). On
  GitHub-hosted Ubuntu 24.04 it does **not** work: AppArmor restricts unprivileged user namespaces on the
  host, so rootlesskit can't start. Public repositories are built by `build-container.yml`'s buildx path
  instead, and their own Dockerfile tests can use the Docker that GitHub's VM provides.
- **Rollout:** `build-container.yml` uses `bk` itself. A new `bk` version reaches callers and workflows only
  once the rebuilt toolbox image is pinned as the `TOOLBOX` digest (in `ci.yml` and `build-container.yml`,
  and in the cluster values).

## Rollout rings

| Ring | Repositories | When |
|---|---|---|
| `canary` | `workingrepo` (private), `anmeldungunihandball` (public) | immediately |
| `stable` | all others | 3 days after the release |

The rings are set in `renovate/default.json` and mirrored in `fleet/repos.json`. Renovate merges minor and
patch updates itself once everything is green; majors are always done by hand. Commit-SHA pins stay.
Automerge is acceptable only as long as `main` and the tags here are protected by a ruleset
(`tools/fleet-rulesets.sh`).

## Releasing the pipeline

1. Set `VERSION` and `PIPELINE_VERSION` in `build-container.yml` to the same value. `self-check` enforces
   that, also against the tag.
2. Toolbox digest: let `toolbox.yml` build on `main`, and put the digest into `TOOLBOX` in `ci.yml` and
   `build-container.yml`. After the first time, Renovate does this by itself.
3. Merge the PR, then create a **signed tag** on the release commit (`git tag -s vX.Y.Z <sha>`), and
   optionally a GitHub release.
4. Add the release commit's SHA to the app cluster's `ClusterImagePolicy` objects and apply them. The homelab
   repository's `k3s-apps/pin-pipeline-release.sh` prepares the edit.
5. Only then raise the callers. A release from a commit that is not on `main` never goes into the policies.

**The order is load-bearing.** If a caller moves before step 4, its next image is signed by a workflow ref
the cluster doesn't trust, and admission rejects it. That is safe, because the old pod keeps running, but
the release is wasted.

## Exceptions

`.security/exceptions.json` in the repository. The pipeline translates it for the scanner:

```json
{
  "exceptions": [
    {
      "id": "CVE-2026-12345",
      "kind": "vulnerability",
      "reason": "The affected function is never called",
      "expires": "2027-01-31"
    }
  ]
}
```

`kind` is `vulnerability` (the default), `misconfiguration`, `secret` or `license`. `reason` and `expires`
are mandatory; after the expiry the finding blocks again. Exceptions apply per check ID, not per file.

## Running trials

| Job | Purpose | Status |
|---|---|---|
| `Shell lint (trial)` | shellcheck over every `.sh` file | reports only; review existing findings first |
| `Runtime images (trial)` | Trivy over the images named in compose files | reports only |

Both appear in the job summary. They join the gate only once their findings are worked off.

## Overview and operations

| Command | Purpose |
|---|---|
| `tools/fleet-status.sh` | pin, open PRs, last run and required check per repository |
| `tools/fleet-rulesets.sh [--apply]` | set `security-gate` as a required check |
