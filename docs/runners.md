# Runners

| Group / label | Used by | Notes |
|---|---|---|
| `arc-ci` (default of input `runner`) | private repositories without their own scale set | ARC scale set on a self-hosted k3s node |
| `arc-<repository>` | exactly one private repository each | one scale set and runner group per trust domain |
| `ubuntu-24.04` (GitHub-hosted) | all public repositories; signing, SBOM upload, DAST, FTPS upload of private repositories | |

The self-hosted runner infrastructure (node setup, ARC values, network policies, quotas) is maintained in the
operator's private infrastructure repository; this page only states the contract the workflows rely on.

## Rules

- Public repositories never run on self-hosted runners: runner groups use `visibility=selected` and
  `allows_public_repositories=false`, and `ci.yml` routes by the API-reported visibility (fail closed).
- Signing never runs on self-hosted runners.
- No deploy runner for images: the runtime pulls signed images. `deploy-static.yml` defaults to
  `["self-hosted","deploy"]` and is for private repositories only; set `deploy-runner` for a GitHub-hosted FTPS upload.
- A repository never runs on a scale set of another trust domain.
- Label changes need `helm uninstall` + `install` (ARC reads labels at creation); do not change the pod template while
  runners hold jobs.

## Job isolation (self-hosted)

- One ephemeral pod per job, `hostUsers: false` (own user namespace), runc, not privileged, capabilities
  `SETUID`/`SETGID` only, no service-account token, `emptyDir` volumes deleted with the pod.
- Network: default-deny; egress only DNS and public HTTP(S); no access to the cluster API, the node, the LAN or
  link-local metadata (verified by a probe matrix).
- Pod image is `ci-toolbox` (digest-pinned, signed by `toolbox.yml`); no Docker daemon. Images are built by rootless
  BuildKit (`bk`) to an OCI tar.
- Rootless BuildKit requires seccomp and AppArmor `Unconfined`, `procMount: Unmasked`, `allowPrivilegeEscalation: true`,
  so the runner namespace cannot enforce Pod Security `baseline`/`restricted` (documented exception; admission
  policies still forbid privileged mode, host namespaces and host paths).
- Sub-IDs: a ConfigMap is mounted over `/etc/subuid` and `/etc/subgid`; the toolbox default is `runner:2000:63000`.
- Runner user is uid 1001 (the `tb` wrapper on GitHub-hosted runners relies on the host `runner` uid).
- GitHub access: private GitHub App with one permission (Organization, Self-hosted runners: read and write); the key
  exists only as a Kubernetes Secret on the node; pods get a just-in-time registration.
- Public repositories build with buildx on GitHub-hosted runners because Ubuntu 24.04 sets
  `kernel.apparmor_restrict_unprivileged_userns=1`.
- `ci-toolbox` stays private: self-hosted pods use a read-only pull secret (`read:packages`); GitHub-hosted jobs log in
  with `GITHUB_TOKEN` (`packages: read`) and the repository must be listed under the package's Manage Actions access.
- Known limit: weaker than a microVM per job; the node is the trust anchor for private builds.

## Versions

| Component | Version | Source |
|---|---|---|
| ARC (gha-runner-scale-set) | 0.15.1 | infrastructure repository |
| Runner base | `actions-runner:2.338.2` | `toolbox/Dockerfile` |
| BuildKit | `v0.34.2` (rootless in toolbox) | `toolbox/Dockerfile` |
