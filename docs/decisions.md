# Decisions and why they were made

This page records every significant design decision of the pipeline: the problem behind it, what was
decided, **why**, which alternatives were considered, and what it costs. It is written so that someone
new can follow the reasoning, and so that the design can be presented.

The infrastructure side (clusters, network, backups, monitoring) is documented in the same format in the
homelab repository (`Homelab-Decisions.md`).

**Status values:** *active* · *superseded by D-n* · *accepted risk*. Sources are PR numbers (`#n` = this
repository), commit hashes, or files in this repository.

---

## At a glance

| # | Decision | In one line: why |
|---|---|---|
| [D-1](#d-1) | One central reusable pipeline with a small contract | Tools and policies are maintained once; repos depend only on one check |
| [D-2](#d-2) | Keyless signing in a separate GitHub-hosted job | No private key that can leak; scanners never hold signing rights |
| [D-3](#d-3) | One release workflow carries policy, gate, build and signature | A valid signature proves the gate ran, even without branch protection |
| [D-4](#d-4) | Release only from a signed merge commit of a PR on `main` | Closes direct pushes and branch releases on GitHub Free |
| [D-5](#d-5) | Trust is pinned to release commits of this repo | A branch with a gutted workflow can sign, but is never trusted |
| [D-6](#d-6) | Signed SBOM and provenance, described honestly as SLSA L1 + signature | Consumers can check contents and origin; no over-claiming |
| [D-7](#d-7) | Dependency-Track reports, it does not gate | New CVEs after release need visibility, but must never stop a signed release |
| [D-8](#d-8) | Strip guessed CPEs from OS packages in the SBOM | Avoids false CVE reports for fixes the distribution backported |
| [D-9](#d-9) | The security gate runs once per release | Only the gate inside the signing workflow counts |
| [D-10](#d-10) | Exceptions in one scanner-neutral file, with reason and expiry | Tool swaps stay invisible; every exception gets a re-decision date |
| [D-11](#d-11) | Ruleset on public repos; private repos accepted as unprotected | GitHub Free can't protect private repos, so the release is protected instead |
| [D-12](#d-12) | **Public code never runs on our own machines** | Fork PRs and public code stay on GitHub's throwaway VMs |
| [D-13](#d-13) | One runner VM per trust domain | Separate Docker daemons per domain (superseded by D-15/D-16) |
| [D-14](#d-14) | Kata microVM per job: tried and abandoned | Nested virtualisation froze under build I/O; an unreliable gate is worse |
| [D-15](#d-15) | Runner pods in their own user namespace, rootless BuildKit | Strong-enough isolation that works on small hardware |
| [D-16](#d-16) | One ARC scale set and runner group per trust domain | A repo never runs on a runner another domain can order |
| [D-17](#d-17) | GitHub App with exactly one permission for ARC | Least privilege; the key never reaches a job |
| [D-18](#d-18) | A specific sub-ID layout for builds in user-namespaced pods | The only layout that maps every ID `apt` needs |
| [D-19](#d-19) | No Docker daemon in CI jobs (v3) | Docker access is root; a daemon is a shared object a job could abuse |
| [D-20](#d-20) | One digest-pinned, private toolbox image for every tool | Same tools and versions everywhere; nothing unscanned |
| [D-21](#d-21) | `bk`: rootless BuildKit with its process sandbox left on | Every build step stays isolated |
| [D-22](#d-22) | Scan the tar, push exactly those bytes, require digest equality | What runs is byte-for-byte what was scanned |
| [D-23](#d-23) | Public images build on GitHub-hosted with buildx | Neither disable a kernel protection nor move public builds onto our hardware |
| [D-24](#d-24) | BuildKit cleanup runs in its user namespace and only warns | A cleanup error must never skip the signature |
| [D-25](#d-25) | Docker stays only where it is the only way | Honest scope of "no Docker" |
| [D-26](#d-26) | Deployments are pulled, never pushed into the LAN | No CI system holds a way into the home network |
| [D-27](#d-27) | The cluster's admission controller decides what runs (v3) | One enforcement point for every workload instead of an agent per host |
| [D-28](#d-28) | Third-party images run only by exact digest | "Only known bytes run" also for vendor images |
| [D-29](#d-29) | Remove the host agent `app-deploy` | Replaced by admission; dead code is attack surface |
| [D-30](#d-30) | Static FTPS deploy: GitHub-hosted, checks itself, never deletes | The target can't check anything; deletions are the riskiest operation |
| [D-31](#d-31) | DAST always on GitHub-hosted runners | Targets are public; the CI network needs no arbitrary egress |
| [D-32](#d-32) | Renovate with digest pins, rings and limited automerge | Updates arrive fast without one bad release reaching every repo at once |

### Timeline

| Date (2026) | Milestone |
|---|---|
| 10-30 | v0.1 to v2.0 in one day: central workflows, keyless signing, release policy, pull-based deploys |
| 11-02 | v2.1 trust pinned to release commits; v2.2 Dependency-Track; v2.3 CPE stripping |
| 11-03 | Runner VM per trust domain; Kata trial on Kubernetes |
| 11-04 | Kata dropped; **v3.0.0**: no Docker daemon, toolbox, rootless BuildKit, admission instead of host agents; v3.0.1 cleanup fix; first signed releases admitted, an unsigned image denied |
| 11-05 | **v3.0.2**: public builds via hosted buildx (rule: public code never on own hardware); `app-deploy` removed |

---

## Supply chain and signing

<a id="d-1"></a>
### D-1 · One central reusable pipeline with a small, stable contract
*2026-10-30 (v0.1.0, contract frozen in v1.0.0, #2) · active*

**Context.** Several repositories (public and private; containers, static sites, CI-only) needed the same
security checks. One maintainer can't keep tool choices current per repository.

**Decision.** Every repository calls reusable workflows (`ci.yml`, `build-container.yml`, `deploy-static.yml`,
`dast.yml`) pinned by commit SHA with a version comment. Callers depend on only four things:
- one required check, `Security / security-gate`;
- tool-neutral inputs;
- the workflow path, which is the signing identity;
- `.security/exceptions.json`.

Job names describe capabilities, never tools. A contract change is a major release.

**Why.** This makes the pipeline swappable: repositories depend on a small contract, and tools change here.
Tools, versions and policies are maintained once.

**Alternatives.**
- **Per-repository pipelines:** the state before; bahnbot and solar had their own release scripts. Rejected
  because of drift and effort.
- **Checks named after tools:** rejected, because a tool swap would then break every repository's ruleset.

**Trade-offs.**
- Breaking changes need a PR in every caller (v1, v2 and v3 each did).
- Callers must set `permissions` as an upper bound for nested jobs. A missing permission shows up only as an
  opaque `startup_failure`.

<a id="d-2"></a>
### D-2 · Keyless signing in a separate GitHub-hosted job
*2026-10-30 (key mode removed in v2.0.0, #5) · active*

**Context.** Consumers must be able to verify who built an image. Early versions also supported a signing
key pair.

**Decision.** Sign **keyless** only: GitHub OIDC to Fulcio, logged in Rekor. Signing runs in a separate
GitHub-hosted job that runs no repository code and no third-party scanner, and it is the only job with
`id-token: write`.

**Why.**
- No private key exists that could leak or would need rotating.
- The certificate binds the signature to the workflow identity and the git ref.
- Separating the job means scanner code (Trivy, Syft, …) never holds signing rights.

**Alternatives.**
- **Key-pair signing:** existed in v0.3. Dropped because it needs signing secrets in repositories.
- **Signing inside the CI cluster:** rejected. The self-hosted node is the weaker trust anchor (see D-15),
  so it must not be able to sign.

**Trade-offs.** Repository and workflow names of private repositories appear in the public Rekor
transparency log; the code does not. Renaming a repository changes the identity, so the cluster policy must
move with it.

<a id="d-3"></a>
### D-3 · One release workflow carries policy, gate, build and signature
*2026-10-30 (v2.0.0, #5) · active*

**Context.** In v1, gate and deploy were separate workflows. A caller could drop a `needs:` or tag an
unmerged branch, the "release-tag hole".

**Decision.** `build-container.yml` runs release policy, security gate, build and signing as **one**
workflow. Consumers accept only a signature of this workflow.

**Why.** A caller can remove a `needs:`, but it can't obtain this workflow's identity without running these
jobs. That holds on GitHub Free too, where `main` of a private repository can't be protected. GitHub
can't block the merge, but the pipeline can refuse the release.

**Alternatives.**
- **A separate deploy workflow guarded by the caller:** v1. Removed because the caller could bypass it.
- **Repository rulesets:** not available for private repositories on GitHub Free.
- **GitHub Pro:** a cost decision against it.

**Trade-offs.** The workflow path is part of the contract and can't be renamed without an overlap period in
the cluster policies. For static FTPS sites no signature exists (D-30).

<a id="d-4"></a>
### D-4 · Release only from a signed merge commit of a PR on `main`
*2026-10-30 (v0.3.0 main-only, policy job in v2.0.0) · active*

**Context.** Only `main` and tags were protected, and private repositories can't be protected at all on the
free plan.

**Decision.** The `policy` job requires all three: the commit is on `main`, it is GitHub-verified
(signed), and it is the merge result of a pull request. A direct push still lands in git, but it never gets
signed, so it never runs.

**Why.** Every release has a visible review trail (a PR), and the keyless certificate is bound to that ref.

**Alternatives.**
- **Relying on branch protection:** impossible for private repositories on GitHub Free.
- **Releasing from tags or branches:** an earlier version had that hole; it was closed in v0.3.0 and v2.1.0.

**Trade-offs.** Every release needs a merged PR; there is no bypass for emergency hotfixes. Commit signing is
a precondition.

<a id="d-5"></a>
### D-5 · Trust is pinned to release commits of this repository
*2026-11-02 (v2.1.0, #6); moved into the cluster policies in v3 · active*

**Context.** The host deployer used to accept a signature from `build-container.yml@<anything>`. Any pushed
branch of this repository with a gutted workflow could have signed images that hosts would run.

**Decision.** Callers pin by commit SHA, so the signing identity ends in `@<sha>`. The consumer allows only
the SHAs of release tags whose commit is on `main`. Today that list lives in the app cluster's
`ClusterImagePolicy` objects. Every release follows the order **tag → SHA into the policies → callers**
(`k3s-apps/pin-pipeline-release.sh` in the homelab repo prepares the edit).

**Why.** This closes the bypass where any branch of this repository could produce an accepted signature.
It was verified against a live signature: the identity ends in the commit SHA, not in a tag name.

**Alternatives.**
- **Matching by tag name:** impossible, because callers pin SHAs and the certificate carries the SHA.
- **Accepting any ref:** the v2.0.0 state, rejected as above.

**Trade-offs.** Each release needs a manual allow-list step before callers may move. Forgetting it makes the
next image unadmittable. That is safe, since the old pod keeps running, but the release is lost. The step
was missed once during the v3.0.0 rollout and caught before any image builder merged.

<a id="d-6"></a>
### D-6 · Signed SBOM and provenance, described honestly as SLSA L1 + signature
*2026-10-30 · active*

**Context.** Consumers should be able to check what an image contains and where it came from.

**Decision.**
- Syft writes a CycloneDX SBOM from the scanned tar.
- A SLSA v1 provenance statement names the repository, `refs/heads/main` and the commit.
- Both are attested and signed. The cluster policies require both.
- The pipeline claims only "SLSA Build L1 plus signature".

**Why.** The provenance is written by a step of a job the repository controls, not by an isolated build
platform, so claiming L2/L3 would be wrong. CycloneDX is what Dependency-Track consumes.

**Alternatives.**
- **SPDX:** used by an earlier solar-only pipeline.
- **`slsa-github-generator` / GitHub attestations for L2/L3:** named as the way up, not adopted yet.

**Trade-offs.** The provenance isn't independent of the build job. The admission controller verifies the
attestations, which carry the same keyless signature from the same signing job, rather than the plain image
signature in bundle form.

<a id="d-7"></a>
### D-7 · Dependency-Track reports, it does not gate
*2026-11-02 (v2.2.0, #9) · active*

**Context.** The Trivy gate passes at build time, and new CVEs appear afterwards. The weekly `image-rescan`
scans only `:latest` and ignores exceptions.

**Decision.** After signing, a GitHub-hosted job with `permissions: {}` and `continue-on-error` uploads the
attested SBOM to Dependency-Track: project = repository, version = commit, tagged with the image digest.
Dependency-Track re-evaluates it daily. It reports only, with no gate and no Telegram alert.

**Why.**
- An outage of Dependency-Track must never stop a release that is already signed.
- The owner chose "tune it instead of gating on it".
- The first run immediately found 12 critical/high findings in `solar` that the gate had passed, which led to D-8.

**Alternatives.** Gating on Dependency-Track, or alerting on every finding: both rejected by the owner.

**Trade-offs.** Findings need manual triage. The upload goes over the public hostname through a narrowly
scoped Cloudflare Access app that opens only `/api/v1/bom`.

<a id="d-8"></a>
### D-8 · Strip guessed CPEs from OS packages in the SBOM
*2026-11-02 (v2.3.0, #11) · active*

**Context.** Dependency-Track reported 12 critical/high CVEs for Debian's `openssl 3.5.7-1~deb13u3`, matched
through a CPE that Syft guessed. Debian backports fixes without changing the upstream version, so a CPE match
against NVD sees an "old" OpenSSL.

**Decision.** Remove `cpe` from `pkg:deb|apk|rpm` components before attesting. Dependency-Track then judges OS
packages by purl against OSV, which is the same distribution data Trivy uses. Language packages keep their CPEs.

**Why.** CPE matching flags CVEs the distribution already fixed. False positives train people to ignore the tool.

**Alternatives.** Suppressing each CVE by hand in Dependency-Track: effort that never ends.

**Trade-offs.** It relies on OSV coverage of the distribution. rpm-based images are untested.

<a id="d-9"></a>
### D-9 · The security gate runs once per release
*2026-11-02 · active*

**Context.** Release workflows ran the gate twice: once through the repository's own `ci.yml`, once inside
`build-container.yml`.

**Decision.** Release workflows call their own `ci.yml` with the security part switched off. Pull requests
still report `Security / security-gate`.

**Why.** Only the gate inside `build-container.yml` counts, because its signature is what the cluster
checks. The duplicate cost CI time on a small cluster.

**Trade-offs.** The nested call still needs the caller to grant `packages: read`. Without it the run ends in
`startup_failure`, which happened on the first v3 releases.

<a id="d-10"></a>
### D-10 · Exceptions in one scanner-neutral file, with reason and expiry
*2026-10-30 (v1.0.0) · active*

**Context.** Scanner-specific ignore files would tie repositories to a tool.

**Decision.** `.security/exceptions.json` holds `id`, `kind`, `reason` (mandatory) and `expires`
(mandatory). The pipeline translates it for whichever scanner is current. After the expiry the finding
blocks again.

**Why.** Tool swaps stay invisible to repositories, and every accepted risk gets a date on which it must be
decided again.

**Trade-offs.** Exceptions apply per check ID, not per file, so one exception covers every file with that
finding.

<a id="d-11"></a>
### D-11 · Ruleset on public repositories; private repositories accepted as unprotected
*2026-10-21 · active · accepted risk for private repos*

**Context.** A push to the public `solar` main was signed and deployed within ten minutes. The signature
proves that the workflow built it, not who committed it.

**Decision.** Public repositories get a ruleset on `main`:
- no deletion, no force push;
- a PR and the status checks are required;
- bypass only for admins inside PRs.

Private repositories can't be protected on GitHub Free. There the pipeline protects the release instead (D-3, D-4).

**Why.** Without the ruleset, anyone with a token of `repo` scope could get code into production.

**Alternatives.** GitHub Pro for private repositories: not worth the cost for a personal setup.

**Trade-offs.** A stolen owner token can still open and merge a PR, but it leaves a visible PR and can't
rewrite history.

---

## CI runners and isolation

<a id="d-12"></a>
### D-12 · Public code never runs on our own machines
*2026-10-30 (visibility check); reaffirmed by the owner 2026-11-05 · active*

**Context.** Self-hosted runners sit next to the home network and execute workflow code. A pull request
from a fork of a public repository is untrusted code.

**Decision.**
- The first job asks the GitHub API for the repository's visibility and fails closed. The visibility is
  never taken from an input or the event payload.
- **Public repositories always run on GitHub-hosted runners, including their image builds.**
- Private repositories run on the CI cluster.
- Signing, SBOM upload, DAST, re-scan and FTPS upload always run GitHub-hosted.
- The org's runner groups additionally refuse public repositories.

The owner's rule, 2026-11-05: *"CI for public repos must run on GitHub. Only the live running instances
are on my servers."*

**Why.** Fork PRs can't reach our hardware, by two independent paths (runner groups and the visibility
check). Our machines run services, not other people's code.

**Alternatives.**
- **Taking visibility from an input:** a caller could lie.
- **An opt-in self-hosted runner for one public repository:** proposed in v3.0.2 for `solar`, and withdrawn
  before release, because it contradicts this rule. See D-23.
- **Running everything GitHub-hosted:** the owner prefers private code on own hardware.

**Trade-offs.** Public repositories take a different execution path (the toolbox via `docker run`, and builds
via buildx) than private ones, although with the same tools and versions.

<a id="d-13"></a>
### D-13 · One runner VM per trust domain
*2026-11-03 · superseded by D-15/D-16 (VMs stopped 2026-11-04)*

**Context.** Every self-hosted runner lived on one VM, as one user, on one rootful Docker daemon. Any
private repository's job could have swapped another repository's image between scan and push, or read the
other runners' credentials.

**Decision.** One VM per repository that ships something, plus one VM for CI-only repositories, each with
its own Docker daemon.

**Why.** Separating daemons means separating root.

**Trade-offs.** Four extra VMs on an overcommitted host, and each still had a rootful daemon. That led to D-15.

<a id="d-14"></a>
### D-14 · Kata microVM per job: tried and abandoned
*built 2026-11-03, abandoned 2026-11-04 · superseded by D-15*

**Context.** The owner chose Kubernetes for CI. Kata Containers would give each job its own guest kernel,
with a privileged Docker-in-Docker inside.

**Decision.** It was built on the CI node (k3s, Kata 4.3.1, ARC) and kept as a trial, then dropped.

**Why it was abandoned.** The node is a VM, so the job microVMs ran nested on a 4-core i5. Under
image-build I/O the guest froze until Kata killed it: 16 times in 25 minutes of normal CI, despite tuning
(direct I/O, more virtiofs threads, sizing). **A security gate that fails at random is worse than one that
is slightly less isolated.**

**Alternatives.** Kata on bare metal would remain the stronger choice, but there is no spare bare-metal host.

<a id="d-15"></a>
### D-15 · Runner pods in their own user namespace, with rootless BuildKit
*2026-11-04 · active*

**Context.** After D-14 a model was needed that works on small, virtualised hardware and keeps any
Docker socket away from jobs.

**Decision.** One pod per job (Actions Runner Controller), configured as follows:
- plain runc, with `hostUsers: false`, so "root" in the pod is an unmapped, unprivileged user on the node;
- not privileged, capabilities only `SETUID`/`SETGID`, no service-account token;
- the pod is deleted after the job.

Rootless BuildKit needs exactly these relaxations, each tested on its own: seccomp and AppArmor
`Unconfined`, `procMount: Unmasked`, `allowPrivilegeEscalation: true`.

**Why.**
- Each relaxation was tested individually, and the failure without it is recorded (see
  [runners.md](runners.md#pitfalls-when-building-this)).
- The unconfined profiles are acceptable because the pod has no capabilities in the host namespace.
- No changes to the node were needed.
- A heavy multi-stage build ran in 74 s at a 1.8 GB peak, without a single freeze.

**Alternatives.**
- **Kata:** D-14.
- **`--oci-worker-no-process-sandbox`:** rejected, because build steps would share a PID namespace with
  BuildKit.
- **Privileged Docker-in-Docker:** rejected, because socket access is root.

**Trade-offs.** It is weaker than a microVM: a kernel bug in user namespaces or mounts would be a path onto
the node, and the node is the trust anchor for every private build.

<a id="d-16"></a>
### D-16 · One ARC scale set and runner group per trust domain
*2026-11-04 · active*

**Context.** The cluster replaced the per-domain VMs (D-13) and had to keep the separation.

**Decision.** There are four scale sets, each named the same as its runner label and runner group:
- `arc-ci`: homelab, workingrepo, knowledgebase;
- `arc-bahnbot`, `arc-pascalhaag-website`, `arc-websiteghana`: one repository each.

Every group has `visibility=selected` and `allows_public_repositories=false`, with `maxRunners: 1`. All
sets share one base values file, so isolation settings and the toolbox digest are identical. The workflows
have an input `runner` (default `arc-ci`).

**Why.** A repository never runs on a runner that another trust domain can order. The input exists because
ARC fixes the label when the scale set is created.

**Alternatives.**
- **One shared `arc-ci` for everything:** the earlier trial. Its group was visible to all repositories.
- **Changing labels with `helm upgrade`:** does nothing.

**Trade-offs.** `maxRunners: 1` serialises each domain. The 5 GB node fits about two jobs at once, so the
others wait.

<a id="d-17"></a>
### D-17 · GitHub App with exactly one permission for ARC
*2026-11-03 · active*

**Decision.** A private GitHub App holds the single permission *Organization → Self-hosted runners: Read and
write*, with no repository rights and no webhooks. Its private key exists only as a Kubernetes Secret
(encrypted at rest). Runner pods receive only a just-in-time registration for one job.

**Why.** Least privilege. A personal access token with `admin:org` would be far broader.

**Trade-offs.** Anyone holding the key could register rogue runners and take jobs of private repositories.
To recover, generate a new key and recreate the Secret.

<a id="d-18"></a>
### D-18 · A specific sub-ID layout for builds in user-namespaced pods
*2026-11-04 · active (moves into the toolbox image later)*

**Context.** A `hostUsers: false` pod owns only IDs 0–65535.

**Decision.** A ConfigMap is mounted over `/etc/subuid` and `/etc/subgid`, with `runner:1:1000` and
`runner:1002:64534`. That covers every pod ID except 0 and the runner's own 1001.

**Why.** The layout came from test evidence:
- `runner:100000:65536` lies outside the pod's range, so `newuidmap` fails.
- `runner:2000:63000` worked, until the first real build ran `apt-get`, which needs ID 65534
  (`setgroups 65534 failed`).
- Pod ID 0 can't be mapped at all.

**Trade-offs.** Until the toolbox image ships the same layout, the cluster's ConfigMap and the image default
differ, and the cluster wins.

---

## Building without Docker

<a id="d-19"></a>
### D-19 · No Docker daemon in CI jobs
*2026-11-04 (v3.0.0) · active*

**Context.** Access to a Docker socket is root-equivalent, and the daemon is a shared object a job could
use to swap a scanned image.

**Decision.** CI and release jobs run every tool from one image and build with rootless BuildKit. On our
machines there is no Docker socket, no Docker-in-Docker and no `privileged`.

**Why.** There is no daemon a job could replace. It also removes the reason for per-VM daemons (D-13) and
for Kata's privileged inner Docker (D-14).

**Trade-offs.** Callers' own Dockerfile tests on the CI cluster have to use `bk` instead of
`docker build`. v3 was therefore a major release.

<a id="d-20"></a>
### D-20 · One digest-pinned, private toolbox image for every tool
*2026-11-04 · active*

**Decision.** `ci-toolbox` contains actionlint, zizmor, Trivy, Syft, TruffleHog, hadolint, shellcheck,
Semgrep, Bandit, Cosign, crane and rootless BuildKit, each copied from its official, digest-pinned image.
- The workflows pin the toolbox by digest in one variable, and Renovate moves it.
- In the cluster the runner pod *is* the toolbox. On GitHub-hosted runners a wrapper runs it with
  `docker run`.
- `toolbox.yml` builds, scans and signs it.
- The package stays **private** (owner decision).

**Why.** Same tools and versions everywhere, and the toolbox adds no new trust. In v2 the tools ran from
separate images, and their own dependencies were never scanned.

**Alternatives.** A public package was briefly planned and reversed the same day.

**Trade-offs.**
- Public callers must be added to the package's access list by hand, in the UI.
- The toolbox itself is in the supply chain and is built with Docker (it can't build itself).
- Semgrep, zizmor and Bandit are installed by version, without hashes.

<a id="d-21"></a>
### D-21 · `bk`: rootless BuildKit with its process sandbox left on
*2026-11-04 · active*

**Decision.** `bk` wraps `buildctl-daemonless.sh`:
- it builds one Dockerfile stage with a fresh state directory per job;
- `image-resolve-mode=pull` makes base images always come from the registry;
- the process sandbox stays on.

**Why.** Every `RUN` step keeps its own PID namespace and a fresh `/proc`, and no cache survives a job.

**Alternatives.** `--oci-worker-no-process-sandbox`: easier to run, but it weakens step isolation. Never used.

**Trade-offs.** It needs `procMount: Unmasked` in the pod (D-15).

<a id="d-22"></a>
### D-22 · Scan the tar, push exactly those bytes, require digest equality
*2026-11-04 · active*

**Decision.** BuildKit writes an OCI tar, which is unpacked once into an OCI layout. Trivy (gate), Syft
(SBOM) and crane (push) all read that same directory. The job fails in two cases:
- the build produced anything other than one manifest;
- the digest the registry reports differs from the manifest digest in the scanned tar.

**Why.** **The pushed image is byte-for-byte what Trivy scanned.** No daemon re-tags or re-exports in between.

**Trade-offs.** Three tool quirks had to be solved: Trivy can't read an OCI-layout *tar*, crane can't push
one, and GHCR returns intermittent "unknown blob" errors, which the job retries.

<a id="d-23"></a>
### D-23 · Public images build on GitHub-hosted runners with buildx
*2026-11-05 (v3.0.2) · active*

**Context.** The first v3 release of the public `solar` failed: GitHub-hosted Ubuntu 24.04 sets
`kernel.apparmor_restrict_unprivileged_userns=1` on the host. That blocks rootless BuildKit inside a
container (`fork/exec /proc/self/exe: permission denied`), and no container option lifts it.

**Decision.** On GitHub-hosted runners, `build-container.yml` builds with a **buildx builder**:
- the docker-container driver, fresh per job, with `--pull --no-cache`;
- running the **same BuildKit release** as the toolbox, `moby/buildkit:v0.34.2`, pinned by digest;
- the same kind of OCI tar comes out (one manifest, no BuildKit-generated attestations).

Scan, SBOM, push, digest check and signing are unchanged. The CI cluster keeps rootless `bk`.

**Why.** Each of the three options was weighed:
1. *Lift the AppArmor restriction with `sysctl` on the hosted VM:* rejected. It switches off a kernel
   protection.
2. *Build public repositories on their own self-hosted scale set:* rejected. It breaks D-12, the owner's rule
   that public code never runs on our machines.
3. *Use the throwaway VM's own Docker and BuildKit:* chosen. It changes no security setting, the VM is
   GitHub's and is discarded, and "no Docker daemon" (D-19) was always about *our* machines. The hosted path
   already used that daemon to start the toolbox.

**Trade-offs.**
- Public and private images are built by different BuildKit front-ends (buildx vs. buildctl), with the same
  BuildKit release.
- The hosted build no longer needs the unconfined container profiles the old path asked for, a small gain.
- `bk` itself still doesn't work on hosted runners.

<a id="d-24"></a>
### D-24 · BuildKit cleanup runs in its user namespace and only warns
*2026-11-04 (v3.0.1, #18) · active*

**Context.** The first real v3 image release built, scanned and pushed, then failed in "Clean up". BuildKit's
snapshot files belong to sub-IDs, and the runner user got "Permission denied". The failed job skipped
signing, which left an unsigned image as `latest` in the registry.

**Decision.**
- The registry login, the tar and the layout are still removed strictly.
- BuildKit's state is removed from inside the same user namespace (`rootlesskit rm -rf`), with only a
  warning if that fails.

**Why.** Pods and hosted VMs are discarded anyway, and a cleanup error must never skip the signature. The
incident also proved the design: admission **denied** the unsigned image twice, and the old version kept
running.

<a id="d-25"></a>
### D-25 · Docker stays only where it is the only way
*2026-11-04 · active*

**Decision.** Docker remains in a few places, each with a stated reason:

| Where | Why Docker is kept |
|---|---|
| Starting the toolbox on GitHub-hosted runners | The only way to run it there |
| Public image builds (D-23) | The VM's own BuildKit is the only working option |
| The sign job's registry login | Cosign needs registry credentials |
| DAST (ZAP, Nuclei) | Those tools don't belong in the toolbox |
| The weekly re-scan | One pinned Trivy image |
| `toolbox.yml` | The bootstrap: the toolbox can't build itself |

All of these run on GitHub's throwaway VMs, never on our machines.

**Why.** It is an honest scope: "no Docker daemon" protects our machines, not every workflow.

---

## Deployment and admission

<a id="d-26"></a>
### D-26 · Deployments are pulled, never pushed into the LAN
*2026-10-12 onward · active (the mechanism changed with D-27)*

**Context.** The applications run in the home network. CI runners must not hold credentials that can reach
into it.

**Decision.** The deployment target pulls signed images and verifies them itself. No CI system ever pushes
into the LAN. Originally this was a systemd timer per host (`app-deploy`), and since v3 it is the cluster's
updater plus admission (D-27). The only push left is the FTPS upload to external shared hosting (D-30).

**Why.** Nothing in CI can reach the home network. A compromised CI run can at most publish an image, and the
consumer still checks that image.

**Alternatives.** An SSH push from a deploy runner with a forced command was rated "good, but needs persistent
runners in the LAN", and it was removed.

<a id="d-27"></a>
### D-27 · The cluster's admission controller decides what runs
*2026-11-04 (v3.0.0) · active*

**Context.** The owner wanted services in Kubernetes, with the same signed-image guarantee. A host agent
only protects hosts that run it.

**Decision.** The Sigstore policy-controller runs as a validating webhook:
- it is **fail-closed**, and `no-match-policy: deny`, so an image without a matching policy is refused;
- there is one `ClusterImagePolicy` per own application, requiring the trusted keyless identity, a CycloneDX
  SBOM attestation and a SLSA provenance that names the repository and `refs/heads/main`.

An in-cluster updater rolls newer builds forward. It accepts only images built *later* than the running one
(replay protection), and admission re-checks every rollout.

**Why.**
- It gives the same promise as the host agent, as one enforcement point for every workload.
- It was tested before go-live: a real signed image was admitted; a wrong repository, an untrusted signer,
  an unsigned image and an unlisted image were all denied.
- In production it denied the unsigned image of D-24.

**Alternatives.**
- **Keeping the agent per host:** D-29.
- **Registry-side rejection with Harbor:** on the roadmap.

**Trade-offs.** Fail-closed means a webhook outage blocks new pods (one updater run hit a webhook timeout, and
the next run succeeded). Every third-party image needs an entry (D-28).

<a id="d-28"></a>
### D-28 · Third-party images run only by exact digest
*2026-11-04 · active*

**Decision.** Vendor images are listed by digest in one policy file, and the manifests reference the same
digests. That covers cloudflared, Postgres, Dependency-Track, NocoDB, Vaultwarden, the monitoring stack, and
the `alpine/k8s` image the updater uses.

**Why.** Keeps "only known bytes run" for images this pipeline didn't build.

**Alternatives.** Allowing by tag (tags are mutable) or by registry (far too broad).

**Trade-offs.** Every vendor update is a two-file change, and without Renovate covering it, that change is a
manual monthly task.

<a id="d-29"></a>
### D-29 · Remove the host agent `app-deploy`
*2026-11-05 (v3.0.2, #19) · active*

**Context.** Every service runs in the app cluster now. The old hosts are stopped rollback copies.

**Decision.** The following were deleted:
- `deployer/` and `tools/fleet-hosts.sh`;
- the host fields in `fleet/repos.json`;
- the deployer checks in `self-check.yml`;
- the Renovate pattern for it;
- every doc reference.

In the homelab, its alert rule and the orphaned website deploy secret are gone too.

**Why.** Code that no longer runs is still attack surface and misleads readers.

**Trade-offs.** Rolling back to a host-based deployment would mean restoring v3.0.1's deployer.

<a id="d-30"></a>
### D-30 · Static FTPS deploy: GitHub-hosted, checks itself, never deletes
*2026-11-02 · active*

**Context.** A deploy VM in the LAN couldn't even reach FTP, because its firewall only allowed 443/80/123
out. The target is public shared hosting that verifies nothing.

**Decision.** `deploy-static.yml` runs GitHub-hosted. It verifies on its own that the commit is on `main` and
that the gate is green. It inspects the artifact (no links, no `..`) and uploads over FTPS, never deleting.

**Why.**
- A deploy VM would only add an FTP egress hole to the home network.
- "A deploy that can delete eventually deletes the wrong thing."

**Trade-offs.**
- A file published by mistake stays online until it is removed by hand.
- Whoever edits the workflow in the repository can bypass the check; there is no signature here.
- Both are stated openly, and an artifact signature is on the roadmap.

<a id="d-31"></a>
### D-31 · DAST always on GitHub-hosted runners
*2026-10-30 (v0.3.0) · active*

**Decision.** ZAP baseline (fails on High) and Nuclei (fails on high/critical, templates pinned) run on
GitHub-hosted runners: against staging before production where it exists, otherwise right after the deploy.
A scan that doesn't run is not a pass.

**Why.** The targets are public URLs, and no repository code is checked out. The self-hosted CI therefore
needs no egress to arbitrary websites.

<a id="d-32"></a>
### D-32 · Renovate with digest pins, rollout rings and limited automerge
*2026-10-30 · active*

**Decision.** One shared Renovate preset handles updates:
- It pins actions and images to digests, including inside `run:` lines and scripts, which Dependabot can't do.
- It waits three days after an upstream release.
- It merges minor and patch updates once every check is green; majors and runtime-image jumps always come as
  a PR for review.

The pipeline's own versions roll out in rings: two canary repositories (one private, one public)
immediately, the rest after three days.

**Why.** Updates arrive quickly, but one bad release reaches two repositories first, not all eight.

**Trade-offs.** Automerge is acceptable only because `main` and the tags of this repository are protected.
