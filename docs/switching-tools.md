# Switching tools

Callers depend only on the contract in the [README](../README.md#calling-the-workflows). Tools live in the digest-pinned `ci-toolbox` image (`toolbox/Dockerfile`) and are called as `tb <tool>`.

| Tool | Role | How to replace |
|---|---|---|
| actionlint, zizmor | workflow lint / security | job `workflow-lint` in `ci.yml` |
| TruffleHog | secrets | job `secrets` in `ci.yml` |
| CodeQL / Semgrep / Bandit | SAST public / private / Python | jobs `sast-public`, `sast-private`, `sast-python` |
| Trivy | fs scan (gate), image scan (release) | `dependencies` in `ci.yml`; image step in `build-container.yml` |
| hadolint | Dockerfile lint | job `dockerfile` |
| Syft, crane, Cosign | SBOM, push, signing | `build-container.yml` (signing identity = workflow path; see below) |
| rootless BuildKit (`bk`) | private image builds | `toolbox/bk`, `toolbox/Dockerfile` |

Replacing a scanner:
1. Add the tool to `toolbox/Dockerfile` (digest-pinned), release the toolbox, bump `TOOLBOX` in `ci.yml` and `build-container.yml`.
2. Add a trial job to `ci.yml`: reports only, always green, not in `needs` of `security-gate`, no `continue-on-error`.
3. Compare findings, then add the job to `needs`, delete the old job, translate `.security/exceptions.json` in the same commit.

Changing the signing identity or renaming `build-container.yml`: first allow both identities in the cluster `ClusterImagePolicy` objects, release, then remove the old one.

`bk [<stage>] [-C <context>] [-f <dockerfile>] [--build-arg K=V]... [buildctl args]` builds one stage with rootless BuildKit; without `--output` it only checks the build, `--output type=oci,dest=x.tar` exports. Works in the CI cluster only (needs `procMount: Unmasked`); does not work on GitHub-hosted Ubuntu 24.04. The process sandbox stays on; never add `--oci-worker-no-process-sandbox`.
