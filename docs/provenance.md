# Provenance and vulnerability attestation

## What changed
- **Provenance is built in the `sign` job**, not in `build`. Inputs: the claims of the sign job's own GitHub OIDC
  token (repository, ref, sha, event_name, run id / attempt, runner environment, repository and owner id,
  `workflow_ref`, and `job_workflow_ref` = builder id, i.e. this reusable workflow at the caller's pinned SHA) and the
  image digest from the `build` job output. The claims are checked against the run context (`GITHUB_REPOSITORY`,
  `GITHUB_SHA`, `GITHUB_REF`). The build job no longer writes `provenance.json` or `subject.txt`; the artifact
  `attestations` carries only SBOM and Trivy JSON (evidence).
- **Builder id** is now `https://github.com/<owner>/security-pipeline/.github/workflows/build-container.yml@<ref>` as
  taken from the token (before: `@vX.Y.Z` from `PIPELINE_VERSION`). Callers pin by SHA, so it is a SHA now.
- **Vulnerability attestation:** `cosign attest --type vuln` (predicate type
  `https://cosign.sigstore.dev/attestation/vuln/v1`) with `trivy image --format cosign-vuln` of the exact scanned OCI
  layout (vuln scanner only, no ignore file, unfixed included). It is evidence: the subject is the digest, the JSON
  is not a trust input. Needs the DB already downloaded by the gate step (`--skip-db-update`).
- **Public repos only** (`needs.gate.outputs.private == 'false'`): additional `actions/attest-build-provenance`
  (SHA-pinned, `push-to-registry`), needs `attestations: write` on the sign job. Skipped for private repos
  (GitHub attestations for private repos need Enterprise). Only the sign job (GitHub-hosted, no ci-toolbox) uses it, so the
  private toolbox does not matter.
- Fields the cluster CUE policies check are unchanged: `predicateType`, `externalParameters.workflow.repository`
  (`https://github.com/<owner>/<repo>`) and `.ref` (`refs/heads/main`).

## Honest SLSA level
**Build L1 plus signature for the cosign provenance; L2 is not claimed.** The provenance is now produced outside the
job that runs the build and contains only platform-asserted values, which removes forgery of the predicate from the
build job (which runs repo-defined Dockerfiles). But the signing job is still a job of the user-controlled
workflow run, not the isolated build platform, and the image digest is a job output of the build job: a compromised
build can still push a different image and the sign job would attest that digest. The signature identity
(`build-container.yml` at main) plus policy/gate jobs remains the real control. The GitHub-generated attestation on
public repos is produced by `actions/attest` through GitHub's Sigstore instance (L2-like origin for the signer
identity), but it too attests the digest handed in by the same workflow; no isolation of the build from the signer
gives L3. We do not claim L2/L3.

## Rollout note
Extra attestations do not break admission (policies select by `predicateType`). On public repos two
`slsa.dev/provenance/v1` attestations exist; both name the caller repo and `refs/heads/main`, so the CUE check
passes either way. Verify with a canary image before relying on it (see PR).
