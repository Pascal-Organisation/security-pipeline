# Runners

| Group / label | Used by | Notes |
|---|---|---|
| `arc-ci` (default of input `runner`) | private repositories without their own scale set | ARC scale set on a self-hosted k3s node |
| `arc-<repository>` | exactly one private repository each | one scale set and runner group per trust domain |
| `ubuntu-24.04` (GitHub-hosted) | all public repositories; publish (scan, SBOM, push), signing, SBOM upload, DAST, FTPS upload of private repositories | |

Node setup, ARC values, network policies and quotas live in the operator's private infrastructure repository; this
page states only the contract the workflows rely on.

## Rules

- Public repositories never run on self-hosted runners: the runner groups with runners use `visibility=selected` and
  `allows_public_repositories=false` (the built-in Default group has no runners), and `ci.yml` routes by the API-reported visibility (fail closed).
- Signing never runs on self-hosted runners.
- No deploy runner for images: the runtime pulls signed images. `deploy-static.yml` defaults to
  `["self-hosted","deploy"]` and is for private repositories only; set `deploy-runner` for a GitHub-hosted FTPS upload.
- A repository never runs on a scale set of another trust domain.
- Label changes need `helm uninstall` + `install` (ARC reads labels at creation); never change the pod template while
  runners hold jobs.

## Job isolation (self-hosted)

- One ephemeral pod per job, `hostUsers: false` (own user namespace), runc, not privileged, capabilities
  `SETUID`/`SETGID` only, no service-account token, `emptyDir` volumes deleted with the pod.
- Network: default-deny; egress only DNS and public HTTP(S); no cluster API, node, LAN or link-local metadata
  (probe matrix).
- Pod image is `ci-toolbox` (digest-pinned, signed by `toolbox.yml`); no Docker daemon; rootless BuildKit (`bk`)
  builds an OCI tar.
- Rootless BuildKit requires seccomp and AppArmor `Unconfined`, `procMount: Unmasked`, `allowPrivilegeEscalation: true`,
  so the runner namespace cannot enforce Pod Security `baseline`/`restricted`. The default scale set (`arc-ci`) has
  since replaced `Unconfined` by a Localhost AppArmor profile and a custom seccomp profile (recorded in the operator's
  private repository, not re-checked live); the other scale sets stay `Unconfined`; admission policies still forbid
  privileged mode, host namespaces and host paths.
- Sub-IDs: a ConfigMap is mounted over `/etc/subuid` and `/etc/subgid`; the toolbox default is `runner:2000:63000`.
- Runner user is uid 1001 (the `tb` wrapper on GitHub-hosted runners relies on the host `runner` uid).
- GitHub access: private GitHub App with one permission (Organization, Self-hosted runners: read and write); the key
  exists only as a Kubernetes Secret on the node; pods get a just-in-time registration.
- Public repositories build with buildx on GitHub-hosted runners (Ubuntu 24.04 sets
  `kernel.apparmor_restrict_unprivileged_userns=1`).
- `ci-toolbox` stays private: self-hosted pods use a read-only pull secret (`read:packages`); GitHub-hosted jobs log in
  with `GITHUB_TOKEN` (`packages: read`) and the repository must be listed under the package's Manage Actions access.
- Limit: weaker than a microVM per job; the node is the trust anchor for private builds.

## Versions

| Component | Version | Source |
|---|---|---|
| ARC (gha-runner-scale-set) | 0.15.1 | infrastructure repository |
| Runner base | `actions-runner:2.338.2` | `toolbox/Dockerfile` |
| BuildKit | `v0.34.2` (rootless in toolbox) | `toolbox/Dockerfile` |
