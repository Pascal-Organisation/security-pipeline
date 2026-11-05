# Runners

| Group / label | Used by | Notes |
|---|---|---|
| `arc-ci` (default of input `runner`) | private repos without own scale set (`homelab`, `workingrepo`, `knowledgebase`) | ARC scale set on a k3s node |
| `arc-bahnbot`, `arc-pascalhaag-website`, `arc-websiteghana` | the repo of the same name | one scale set and runner group per trust domain |
| `ubuntu-24.04` (GitHub-hosted) | all public repos; signing, SBOM upload, DAST, FTPS upload of private repos | |

## Rules

- Public repos never run on self-hosted runners: runner groups use `visibility=selected` and `allows_public_repositories=false`, and `ci.yml` routes by the API-reported visibility.
- Signing never runs in the CI cluster.
- No deploy runner: the cluster pulls signed images. `deploy-static.yml` defaults to `["self-hosted","deploy"]` and is for private repos only; set `deploy-runner` for a GitHub-hosted FTPS upload.
- A repo never runs on a scale set of another trust domain.
- Label changes need `helm uninstall` + `install` (ARC reads labels at creation); do not change the pod template while runners hold jobs.

## Job isolation

- One pod per job, `hostUsers: false` (own user namespace), runc, not privileged, capabilities `SETUID`/`SETGID`, no service-account token, `emptyDir` volumes deleted with the pod.
- Pod image is `ci-toolbox` (digest-pinned, signed by `toolbox.yml`); no Docker daemon. Images are built by rootless BuildKit (`bk`) to an OCI tar.
- Rootless BuildKit requires: seccomp and AppArmor `Unconfined`, `procMount: Unmasked`, `allowPrivilegeEscalation: true`. The runner namespace must not enforce Pod Security `baseline`/`restricted`.
- Sub-IDs: the cluster mounts a ConfigMap over `/etc/subuid` and `/etc/subgid` (`runner:1:1000`, `runner:1002:64534`); the toolbox default is `runner:2000:63000`.
- Runner user is uid 1001 (the `tb` wrapper on GitHub-hosted runners relies on the host `runner` uid).
- GitHub access: private GitHub App with one permission (Organization, Self-hosted runners: read and write); key only as a Kubernetes Secret on the node; pods get a just-in-time registration.
- The node firewall allows only DNS, 80/443, NTP.
- Public repos build with buildx (BuildKit v0.34.2) on GitHub-hosted runners because Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`.
- `ci-toolbox` stays private: cluster pods use the `ghcr-pull` secret (`read:packages`); GitHub-hosted jobs log in with `GITHUB_TOKEN` (`packages: read`) and the repo must be listed under Manage Actions access.
- Known limit: weaker than a microVM per job; the node is the trust anchor for private builds.

## Versions and files

| Component | Version | Source |
|---|---|---|
| k3s | v1.36.5+k3s1 | `runners/arc/node-install.sh` |
| Helm | v4.3.1 | `runners/arc/node-install.sh` |
| ARC (gha-runner-scale-set) | 0.15.1 | `runners/arc/scale-set-values.yaml` |
| Runner base | `actions-runner:2.338.2` | `toolbox/Dockerfile` |
| BuildKit | `v0.34.2` (rootless in toolbox) | `toolbox/Dockerfile` |

Example values without secrets: [`runners/arc/`](../runners/arc/).
