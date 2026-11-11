# Provenance and vulnerability attestation

## How it is built

- **Provenance comes from the `sign` job**, not from `build`. Inputs: the claims of the sign job's own GitHub OIDC
  token (repository, ref, sha, event_name, run id / attempt, runner environment, repository and owner id,
  `workflow_ref`, and `job_workflow_ref` = builder id) and the image digest from the `publish` job (D-43). The
  claims are checked against `GITHUB_REPOSITORY`, `GITHUB_SHA` and `GITHUB_REF`. The build job writes no
  `provenance.json` or `subject.txt`; the artifact `attestations` holds only SBOM and Trivy JSON (evidence).
- **Builder id** is `https://github.com/<owner>/security-pipeline/.github/workflows/build-container.yml@<ref>`, taken
  from the token. Callers pin by SHA, so it is a SHA (earlier: `@vX.Y.Z` from `PIPELINE_VERSION`).
- **Vulnerability attestation:** `cosign attest --type vuln` (predicate type
  `https://cosign.sigstore.dev/attestation/vuln/v1`) with `trivy image --format cosign-vuln` of the exact scanned OCI
  layout (vuln scanner only, no ignore file, unfixed included). It is evidence: the subject is the digest, the JSON
  is not a trust input. It needs the DB already downloaded by the gate step (`--skip-db-update`).
- **Deferred to v4.0.0:** GitHub-generated provenance (`actions/attest-build-provenance`) for public repos. It needs
  `attestations: write` in every caller's build job, a caller contract change (major release); the v3.1.0 canary
  failed at startup without it (D-41).
- Fields the cluster CUE policies check are unchanged: `predicateType`, `externalParameters.workflow.repository`
  (`https://github.com/<owner>/<repo>`) and `.ref` (`refs/heads/main`).

## SLSA level

**Build L1 plus signature; L2 is not claimed.** The provenance is produced outside the job that runs the build and
contains only platform-asserted values, so the build job (which runs repo-defined Dockerfiles) cannot forge it.

Since D-43 the `build` job has a read-only token and only uploads the OCI tar as a workflow artifact. The `publish`
job (GitHub-hosted, no repo code, no checkout) treats the tar as hostile: it accepts only plain OCI layout files,
requires exactly one manifest, recomputes the manifest digest and every blob digest, scans, pushes, and reports the
digest the registry returned (equal to the computed one). The `sign` job attests that digest. A compromised build
therefore cannot push an image under another digest, overwrite `latest`, or make the sign job attest a digest it did
not hand over as bytes.

Not L3, not claimed:

- `build` and `publish` belong to the same caller-controlled workflow run. The build does not sign or attest the
  artifact, so `publish` proves what the bytes are, not that they came from the Dockerfile at that commit. A
  compromised build can hand over a different (but scanned and gated) image, which is then signed with this
  workflow's identity.
- The signing identity is the reusable workflow's, shared by all its jobs; there is no per-job builder identity and no
  isolated generator of the build parameters (they come from OIDC claims).
- Private builds run on our own ephemeral runners; the node is the trust anchor ([runners.md](runners.md)).
- Builds are not reproducible (G-A7), so nobody can re-derive the image independently.

The planned GitHub-generated attestation for public repos (D-41) would add an L2-like origin for the signer identity,
but would still attest the digest handed in by the same run. L2/L3 are not claimed.

## Rollout

Extra attestations do not break admission (policies select by `predicateType`). Public repos carry two
`slsa.dev/provenance/v1` attestations; both name the caller repo and `refs/heads/main`, so the CUE check passes.
Verify with a canary image before relying on it.
