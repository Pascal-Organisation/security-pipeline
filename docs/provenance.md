# Provenance and vulnerability attestation

## What changed
- **Provenance is built in the `sign` job**, not in `build`. Inputs: the claims of the sign job's own GitHub OIDC
  token (repository, ref, sha, event_name, run id / attempt, runner environment, repository and owner id,
  `workflow_ref`, and `job_workflow_ref` = builder id, i.e. this reusable workflow at the caller's pinned SHA) and the
  image digest from the `publish` job output (D-43). The claims are checked against the run context (`GITHUB_REPOSITORY`,
  `GITHUB_SHA`, `GITHUB_REF`). The build job no longer writes `provenance.json` or `subject.txt`; the artifact
  `attestations` carries only SBOM and Trivy JSON (evidence).
- **Builder id** is now `https://github.com/<owner>/security-pipeline/.github/workflows/build-container.yml@<ref>` as
  taken from the token (before: `@vX.Y.Z` from `PIPELINE_VERSION`). Callers pin by SHA, so it is a SHA now.
- **Vulnerability attestation:** `cosign attest --type vuln` (predicate type
  `https://cosign.sigstore.dev/attestation/vuln/v1`) with `trivy image --format cosign-vuln` of the exact scanned OCI
  layout (vuln scanner only, no ignore file, unfixed included). It is evidence: the subject is the digest, the JSON
  is not a trust input. Needs the DB already downloaded by the gate step (`--skip-db-update`).
- **Deferred to v4.0.0:** an additional GitHub-generated provenance (`actions/attest-build-provenance`) for public repos.
  It needs `attestations: write` in every caller's build job, which is a caller contract change (major release);
  the v3.1.0 canary failed at startup without it (D-41).
- Fields the cluster CUE policies check are unchanged: `predicateType`, `externalParameters.workflow.repository`
  (`https://github.com/<owner>/<repo>`) and `.ref` (`refs/heads/main`).

## Honest SLSA level
**Build L1 plus signature for the cosign provenance; L2 is not claimed.** The provenance is produced outside the
job that runs the build and contains only platform-asserted values, which removes forgery of the predicate from the
build job (which runs repo-defined Dockerfiles).

Since D-43 the job that runs repo code (`build`) has a read-only token: it cannot push, tag or sign, and it reports no
output. It only uploads the OCI tar as a workflow artifact. The `publish` job (GitHub-hosted, never self-hosted, no
repo code, no checkout) treats that tar as hostile input: it accepts only plain OCI layout files, requires exactly one
manifest, recomputes the manifest digest and every blob digest from the bytes, scans, pushes with the registry write
permission and reports the digest that the registry returned and that equals the one it computed. The `sign` job attests
that digest. So the digest is now computed by a job that runs no repo code, and a compromised build can no longer push
an image of its own choosing under another digest, overwrite `latest`, or make the sign job attest a digest it did not
hand over as bytes.

Still not L3 (and not claimed):
- `build` and `publish` are jobs of the same caller-controlled workflow run. The artifact is not signed or attested by
  the build, so `publish` cannot prove that the bytes came from the Dockerfile at that commit; it only proves what the
  bytes are. A compromised build can still hand over a different (but scanned and gated) image, and that image gets
  signed with this workflow's identity.
- The signing identity is the reusable workflow's, shared by all jobs in it; there is no separate, non-falsifiable
  builder identity per job and no isolated generator of the provenance's build parameters (they come from OIDC claims
  of the run).
- Private builds run on our own ephemeral runners; the node is the trust anchor (docs/runners.md), not an isolated
  platform with attested hardening.
- The builds are not reproducible (G-A7), so nobody can re-derive the image independently.
The GitHub-generated attestation on public repos (planned, D-41) would add an L2-like origin for the signer identity,
but it too would attest the digest handed in by the same workflow run. We do not claim L2/L3.

## Rollout note
Extra attestations do not break admission (policies select by `predicateType`). On public repos two
`slsa.dev/provenance/v1` attestations exist; both name the caller repo and `refs/heads/main`, so the CUE check
passes either way. Verify with a canary image before relying on it (see PR).
