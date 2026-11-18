#!/usr/bin/env bash
#
# release — the owner's one release command (D-53). Run it on the laptop that holds the signing key.
#
#   tools/release.sh [--dry-run] <vX.Y.Z | patch | minor>
#
# Checks a clean, up-to-date main whose VERSION equals the requested version, creates the signed annotated
# tag with your own signing key (user.signingkey; the trust root stays here), verifies it against
# .github/allowed_signers as committed on origin/main, pushes it and waits for the workflow release.yml,
# which creates the GitHub Release (--verify-tag). This script never creates the Release itself: a Release
# for a missing tag would create an unsigned lightweight tag (D-44).
#
# `patch` / `minor` only compute the next version from VERSION; when main does not carry it yet, the script
# stops and names the bump PR to create first (workflow release-pr.yml).
set -euo pipefail

SIGNERS_PATH=".github/allowed_signers"
dry=0
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
[ "$#" -eq 1 ] || { sed -n '3,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
arg="$1"

step() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() { if [ "$dry" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

cd "$(git rev-parse --show-toplevel)"
for c in git gh ssh-keygen; do command -v "$c" >/dev/null || die "$c not found"; done

step "fetch origin"
git fetch --quiet --tags origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main (git switch main)"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "local main differs from origin/main (git pull --ff-only)"

current="$(git show origin/main:VERSION | tr -d '[:space:]')"
[[ "$current" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "VERSION on main is not vX.Y.Z: $current"
maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; pat="${BASH_REMATCH[3]}"

case "$arg" in
  patch) version="v$maj.$min.$((pat + 1))"; kind="patch" ;;
  minor) version="v$maj.$((min + 1)).0"; kind="minor" ;;
  v[0-9]*.[0-9]*.[0-9]*) version="$arg"; kind="" ;;
  *) die "argument must be vX.Y.Z, patch or minor" ;;
esac
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: $version"

if [ "$version" != "$current" ]; then
  echo "VERSION on main is $current, not $version: a version-bump PR has to be merged first."
  echo "Open it (no hand edits; auto-merges when green):"
  echo "  gh workflow run release-pr.yml -f bump=${kind:-patch}   # patch | minor | major"
  echo "then wait for the merge and run this script again with $version."
  exit 3
fi

step "tag $version must not exist (local or remote)"
git rev-parse -q --verify "refs/tags/$version" >/dev/null && die "tag $version exists locally"
[ -z "$(git ls-remote --tags origin "refs/tags/$version")" ] || die "tag $version exists on origin"
gh release view "$version" >/dev/null 2>&1 && die "a release $version exists already"

key="$(git config --get user.signingkey || true)"
[ -n "$key" ] || die "user.signingkey is not set"
[ "$(git config --get gpg.format || true)" = ssh ] || die "gpg.format is not ssh"
signers="$(mktemp)"; trap 'rm -f "$signers"' EXIT
git show "origin/main:$SIGNERS_PATH" > "$signers" || die "$SIGNERS_PATH missing on origin/main"
sha="$(git rev-parse HEAD)"
echo "commit $sha, signing key $key"

step "create signed annotated tag $version"
run git tag -s -a "$version" "$sha" -m "$version"

if [ "$dry" = 0 ]; then
  step "verify tag"
  [ "$(git cat-file -t "$version")" = tag ] || die "$version is not an annotated tag"
  git -c "gpg.ssh.allowedSignersFile=$signers" tag -v "$version" || { git tag -d "$version" >/dev/null; die "signature does not verify against $SIGNERS_PATH; tag deleted locally"; }
  [ "$(git rev-parse "$version^{commit}")" = "$sha" ] || die "tag points to a different commit"
fi

step "push tag"
run git push origin "refs/tags/$version"

step "wait for release.yml"
if [ "$dry" = 1 ]; then
  echo "[dry-run] gh run watch (release.yml, $version); then: gh release view $version --json url"
  exit 0
fi
run_id=""
for _ in $(seq 1 30); do
  run_id="$(gh run list --workflow release.yml --branch "$version" --event push --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$run_id" ] && break
  sleep 2
done
[ -n "$run_id" ] || die "release.yml did not start; check the Actions tab. The tag is pushed: do not create the Release by hand."
gh run watch "$run_id" --exit-status || die "release.yml failed (gh run view $run_id --log-failed)"
gh release view "$version" --json url --jq .url
