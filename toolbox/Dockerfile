# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#
# ci-toolbox — every tool the pipeline runs, in one image, so CI jobs need NO Docker daemon.
#
#   * Self-hosted: this IS the runner image of the ARC scale set (Kubernetes, user namespaces, not privileged).
#   * GitHub-hosted: jobs run in it as `container:`.
# Tools are copied from their official images, each pinned by digest (Renovate moves the pins), so the toolbox
# adds no new trust. Images are built with rootless BuildKit (buildctl-daemonless.sh) into an OCI tar that
# Trivy/Syft scan and crane pushes byte for byte.
#
# Built, scanned, SBOM-attested and keyless-signed by .github/workflows/toolbox.yml.

FROM aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c AS trivy
FROM anchore/syft:v1.55.0@sha256:4cc92b64ca74ffca4c94d4c8fcc01f217731375300be14d0b6eeb2e82eaa110a AS syft
FROM ghcr.io/trufflesecurity/trufflehog:3.99.7@sha256:0d003fc3abc4e1565eca8462b992001314de51451e96e3c44de80d116794d5d1 AS trufflehog
FROM rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 AS actionlint
FROM hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d AS hadolint
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck
FROM ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d AS cosign
FROM gcr.io/go-containerregistry/crane:v0.22.1@sha256:1f968817b95790bed063f71175aa6b8ff879fa17064020415f3e18bb6e6a36e1 AS crane
FROM moby/buildkit:v0.34.2-rootless@sha256:c8252268760e1baba80780d63d738ef9f260fb7c7c0973c78494cb9ddd99eda1 AS buildkit

FROM ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232
ARG SEMGREP_VERSION=1.183.0
ARG ZIZMOR_VERSION=1.31.1
ARG BANDIT_VERSION=1.9.4
USER root
# uidmap: newuidmap/newgidmap for rootless BuildKit; python3-venv for Semgrep/zizmor/Bandit
# upgrade: the base image lags Ubuntu security fixes (Trivy found e.g. libbrotli1)
RUN apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends uidmap python3-venv jq git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 # The runner bundles Node for JavaScript actions; it never uses the npm that ships with it, and that npm
 # carries known-vulnerable dependencies (tar, minimatch, glob, ...). Remove npm/npx, keep node.
 && rm -rf /home/runner/externals/node*/lib/node_modules/npm /home/runner/externals/node*/lib/node_modules/corepack \
           /home/runner/externals/node*/bin/npm /home/runner/externals/node*/bin/npx /home/runner/externals/node*/bin/corepack \
 # no Docker daemon in this design: drop the base image's docker/containerd/runc (unused, and Trivy findings)
 && rm -rf /usr/bin/docker* /usr/bin/containerd* /usr/bin/ctr /usr/bin/runc /usr/local/lib/docker /usr/libexec/docker
COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=syft /syft /usr/local/bin/syft
COPY --from=trufflehog /usr/bin/trufflehog /usr/local/bin/trufflehog
COPY --from=actionlint /usr/local/bin/actionlint /usr/local/bin/actionlint
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY --from=crane /ko-app/crane /usr/local/bin/crane
COPY --from=buildkit /usr/bin/buildctl /usr/bin/buildkitd /usr/bin/buildkit-runc /usr/bin/rootlesskit /usr/bin/buildctl-daemonless.sh /usr/local/bin/
RUN python3 -m venv /opt/py \
 && /opt/py/bin/pip install --no-cache-dir --disable-pip-version-check \
      "semgrep==${SEMGREP_VERSION}" "zizmor==${ZIZMOR_VERSION}" "bandit==${BANDIT_VERSION}" \
 && ln -s /opt/py/bin/semgrep /opt/py/bin/zizmor /opt/py/bin/bandit /usr/local/bin/ \
 # rootless BuildKit maps build-container users into this range. It must lie inside the ids a
 # user-namespaced pod owns (0-65535, hostUsers: false) and above runner's uid 1001.
 && echo "runner:2000:63000" > /etc/subuid && echo "runner:2000:63000" > /etc/subgid \
 # every tool must start; a broken COPY path fails the build here, not in a pipeline run
 && trivy --version >/dev/null && syft version >/dev/null && trufflehog --version >/dev/null 2>&1 \
 && actionlint --version >/dev/null && hadolint --version >/dev/null && shellcheck --version >/dev/null \
 && cosign version >/dev/null 2>&1 && crane version >/dev/null && buildctl --version >/dev/null \
 && buildkitd --version >/dev/null && rootlesskit --version >/dev/null \
 && semgrep --version >/dev/null && zizmor --version >/dev/null && bandit --version >/dev/null
# tells the workflows' `tb` wrapper (ci.yml) to run tools directly instead of via docker run
ENV TOOLBOX_NATIVE=1
USER runner
LABEL org.opencontainers.image.source="https://github.com/Pascal-Organisation/security-pipeline" \
      org.opencontainers.image.description="security-pipeline CI toolbox: runner + scanners + rootless BuildKit, no Docker daemon"
