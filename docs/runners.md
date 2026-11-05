# Self-hosted runners

Private repositories of the organisation build on our own hardware (Proxmox), in a Kubernetes cluster, with
a fresh pod per job. Public repositories never use these runners (see the end of this page). This page
describes how a job is separated from the node and from other jobs, what came before, and what goes wrong
when you rebuild it.

## Current state

| What | How | Status |
|---|---|---|
| **CI cluster:** ARC on k3s, **one pod per job** in its own user namespace | [Actions Runner Controller](https://github.com/actions/actions-runner-controller); pod = `ci-toolbox` image, no Docker daemon, images built by rootless BuildKit in the pod; the pod is deleted after the job | v3, one scale set per trust domain |
| One runner VM per trust domain | one VM per repo, each with its own rootful Docker daemon | **superseded** (v2; VMs stopped 2026-11-04) |
| ARC with a **Kata microVM** per job | built; not stable when nested on small hardware | **rejected** |

An example configuration of the cluster is in [`runners/arc/`](../runners/arc/), without secrets and
without homelab internals.

## Why any of this

At first, every self-hosted runner ran persistently on **one** VM, as **one** Linux user, against **one**
rootful Docker daemon. Access to the Docker socket is effectively root. A job of any private repository
could have done two things, for example through a compromised dependency in a Renovate PR:

- **Swap another repository's image** between the Trivy scan and the push. The signature would still have
  been valid: it proves that `build-container.yml` ran, not what the runner built.
- **Read the other runners' registration data** and take over their jobs, including a `GITHUB_TOKEN` with
  `packages: write`.

v2 separated that with one VM per trust domain. v3 goes further: a job gets neither a Docker daemon nor a
Docker socket, and nothing survives it.

## v3: one pod per job, user namespace, rootless BuildKit

```
GitHub ◄──── outbound only (443) ────────────────────────────────────┐
                                                                     │
k3s node (VM, Proxmox firewall: default deny, no LAN)                │
├─ arc-systems/  controller + listeners  ── GitHub App token ────────┘
└─ arc-runners/  one pod per job, runc, hostUsers: false
     └─ runner = ci-toolbox (digest-pinned, cosign-signed)
          ├─ every tool runs natively (actionlint, zizmor, Trivy, Semgrep, …)
          └─ rootless BuildKit (buildctl-daemonless) → OCI tar → crane push
```

- **One image for everything.** `ci-toolbox` (`toolbox/Dockerfile`, built and signed by `toolbox.yml`)
  contains the runner and every tool. In the cluster the pod *is* the toolbox (`TOOLBOX_NATIVE=1`). On
  GitHub-hosted runners the wrapper `tb` starts the same image with `docker run`. Same steps, same versions.
- **A user namespace instead of a microVM.** With `hostUsers: false`, every pod gets its own Linux user
  namespace, and "root" in the pod is an unprivileged, unmapped user on the node. The pod is not privileged
  and has only the capabilities `SETUID`/`SETGID` (for `newuidmap`/`newgidmap`).
- **No Docker.** Rootless BuildKit builds images in the pod (`--output type=oci`), and `crane` pushes the
  *scanned* tar. There is no daemon a job could replace.
- **One scale set and one runner group per trust domain:** `arc-ci` (homelab, workingrepo,
  knowledgebase), `arc-bahnbot`, `arc-pascalhaag-website`, `arc-websiteghana`. Each group has
  `visibility=selected` and `allows_public_repositories=false`. A repository never runs on a runner that
  another trust domain can order.

| Attack from a job | Result |
|---|---|
| Container escape from a scanner or the build | lands in the pod, in its own user namespace, without rights on the node |
| root in the pod | an unprivileged, unmapped user on the node |
| Leaving traces for later jobs | the pod and all its volumes (`emptyDir`) are deleted after the job; base images are always pulled fresh |
| The Kubernetes API | runner pods have no service-account token, and the service account has no rights |
| Reaching into the LAN | the node's firewall allows only DNS, 80/443 and NTP |

**Access to GitHub:** a dedicated private GitHub App with **exactly one** permission, *Organization →
Self-hosted runners: Read and write*. It has no repository rights and no webhooks. Its key exists only as a
Kubernetes Secret on the node (k3s with `secrets-encryption`). Runner pods never see it: they get a
just-in-time registration for exactly one job.

**Limits, stated openly:**
- **Rootless BuildKit needs relaxations:** seccomp and AppArmor `Unconfined`, `procMount: Unmasked` and
  `allowPrivilegeEscalation: true`. That is acceptable because the pod runs in its own user namespace,
  without capabilities in the *host* namespace. It is still **weaker than a microVM**:
  - A kernel bug in user namespaces or mounts would be a path onto the node, so the node is the trust
    anchor for all private builds.
  - With the App key, someone could register rogue runners and take jobs of private repositories.
- **No PSA enforce:** the runner namespace must not carry Pod Security `enforce=baseline/restricted`.
- **Sub-IDs:** the cluster's sub-ID layout (`runner-subids` ConfigMap, see pitfall 5) overrides the toolbox's
  built-in default until the toolbox image ships the same layout.
- **The toolbox** is part of the supply chain itself. It is built with Docker on a GitHub-hosted runner,
  because it can't build itself.
- **The `ci-toolbox` package stays private** (owner decision; its visibility is never changed).
  - Cluster pods pull it with a read-only `imagePullSecret` (`ghcr-pull`, only `read:packages`).
  - GitHub-hosted runners log in with the `GITHUB_TOKEN` (`packages: read`).
  - For that, **every** caller repository that runs on GitHub-hosted runners must be listed under
    *Packages → ci-toolbox → Package settings → Manage Actions access* with role **Read**. This is UI-only.

### The scale set label

Private repositories run on their domain's scale set (`runs-on` = the scale set's name). `ci.yml` and
`build-container.yml` have the input `runner` for that (default `arc-ci`); callers pass `arc-<repo>`.
Public repositories ignore it and always run on GitHub-hosted runners.

### Pitfalls when building this

For anyone rebuilding this: each of these made jobs fail.

1. **Seccomp `RuntimeDefault` blocks rootlesskit.** `clone`/`unshare(CLONE_NEWUSER)` fails with
   `fork/exec /proc/self/exe: operation not permitted`. Use profile `Unconfined`.
2. **AppArmor `RuntimeDefault` forbids rootlesskit's mounts** (`failed to share mount point: /: permission
   denied`). Use profile `Unconfined`.
3. **`procMount: Unmasked`** (allowed only together with `hostUsers: false`). runc mounts a fresh `/proc` for
   every `RUN` step, and that fails against the masked `/proc` (`error mounting "proc"`). We deliberately do
   **not** use `--oci-worker-no-process-sandbox`, because then RUN steps would share the PID namespace with
   `buildkitd`. BuildKit's process sandbox stays on, and `bk` never sets that flag.
4. **`allowPrivilegeEscalation: true`.** With `no_new_privs` the setuid helper `newuidmap` can't map the
   sub-IDs.
5. **Sub-IDs must lie inside the pod's namespace.** A `hostUsers: false` pod owns only IDs 0–65535, so an
   entry like `runner:100000:65536` is out of range and `newuidmap` fails. A small range such as
   `runner:2000:63000` works for simple builds, but then IDs above 64999 (for example 65534 `nobody`, used
   by `apt-get`) are unmapped: `setgroups 65534 failed`. The cluster therefore mounts a ConfigMap over
   `/etc/subuid` and `/etc/subgid` with `runner:1:1000` and `runner:1002:64534`. That maps every pod ID
   except 0 and the runner's own 1001. Pod ID 0 itself can't be mapped.
6. **The runner user is uid 1001.** The `tb` wrapper on GitHub-hosted runners relies on the toolbox user
   having the same uid as the host's `runner` user. Otherwise files in the workspace belong to a foreign
   owner.
7. **`XDG_RUNTIME_DIR` is missing.** The image has no `/run/user/1001`, so the BuildKit socket and state
   live on writable `emptyDir` volumes.
8. **`emptyDir` on disk, not `medium: Memory`.** A build's layer storage must not count as RAM.
9. **ARC sets labels only when the scale set is created.** A `helm upgrade` with new labels changes nothing
   on GitHub, and jobs stay unassigned. Changing labels means `helm uninstall` + `install`.
10. **Don't change the pod template while runners hold jobs.** ARC then replaces runners that GitHub has
    already assigned jobs to, and those jobs hang until the run is cancelled.
11. **A private registry package.**
    - In the cluster: without an `imagePullSecret` the pod shows `ErrImagePull`, and the job waits for a
      runner forever.
    - On GitHub-hosted runners: `unauthorized` if the `GITHUB_TOKEN` login is missing, or if the caller
      repo isn't listed under *Manage Actions access* (role Read).
12. **`newuidmap` needs file capabilities instead of setuid-root.**
    - A setuid-root helper in a pod without `CAP_DAC_OVERRIDE` can't open `/proc/<pid>/uid_map` of the
      runner-owned rootlesskit process (`newuidmap: open of uid_map failed: Permission denied`).
    - With `DAC_OVERRIDE` it fails differently: `write to uid_map failed: Operation not permitted`.
    - The toolbox therefore sets `cap_setuid+ep`/`cap_setgid+ep` and removes the setuid bit, the same way
      the BuildKit rootless image does.
13. **Rootless BuildKit cleanup.** BuildKit's snapshot files belong to sub-IDs, so the runner user can't
    `rm -rf` them. `build-container.yml` deletes them from inside the same user namespace
    (`rootlesskit rm -rf`) and only warns if that fails. v3.0.0 failed its first release here: the push had
    already happened, so signing was skipped.
14. **GitHub-hosted Ubuntu 24.04 blocks rootless BuildKit.** It sets `kernel.apparmor_restrict_unprivileged_userns=1`
    on the host. A container's `apparmor=unconfined` doesn't lift that, so rootlesskit fails with
    `fork/exec /proc/self/exe: permission denied`. Public repositories therefore build with a buildx builder
    (same BuildKit release) on the hosted VM. We don't lift a kernel restriction for this, and we don't move
    public builds onto our own runners (see [decisions.md](decisions.md#d-23)).

### Why not Kata

The first approach was a Kata microVM per job: its own guest kernel, with a privileged `docker:dind` inside.
The isolation is stronger, but the node is itself a VM, so the microVMs ran **nested** on a small 4-core
host.
- Light jobs ran fine.
- Under image builds (pull, `docker build`, `docker save`, Trivy on the tar), the guest froze long enough
  for Kata to declare its agent dead (`CheckRequest timed out`, `Dead agent`). That happened 16 times in
  25 minutes of normal CI.
- A security gate that fails at random is worse than one that is less strongly isolated.

User namespaces need no guest kernel, no virtio-fs and no nested KVM, and the same heavy build ran without
a hang. On bare metal, Kata would still be the stronger choice.

### Versions

Everything is pinned, and images by digest (see `runners/arc/`).

| Component | Version |
|---|---|
| k3s | v1.36.5+k3s1 (binary checked against `sha256sum-amd64.txt`) |
| Helm | v4.3.1 (checked against the published SHA-256) |
| ARC (controller + scale sets) | 0.15.1 |
| Runner/toolbox | `ci-toolbox` (base `ghcr.io/actions/actions-runner:2.338.2`), by digest in `ci.yml`/`build-container.yml` |
| BuildKit | `moby/buildkit:v0.34.2-rootless` in the toolbox; `moby/buildkit:v0.34.2` (digest-pinned) as the buildx builder on GitHub-hosted runners |

## Public repositories

The org's runner groups don't admit public repositories, and `ci.yml` reads the visibility from the API and
always sends public repositories to GitHub-hosted runners. A fork PR therefore can't reach our runners, by
two independent paths. This is a standing rule: **public code runs on GitHub's machines, only the running
services live on ours.** Signing runs GitHub-hosted in every case.
