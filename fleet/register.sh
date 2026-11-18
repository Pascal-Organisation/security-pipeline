#!/usr/bin/env bash
#
# fleet-register — find organisation repos that fleet/repos.json does not list and propose them in ONE PR.
# Candidates: org repos that are not archived, not forks and not named in "unmanaged_repos" of repos.json.
# Each gets a stub entry (defaults below, "todo": true, a "note" asking the owner to confirm); drift tooling reads
# only the keys it knows, so the extra keys are ignored. Commits are made with the contents API as a GitHub App:
# GitHub signs those commits itself ("verified"), so the ruleset "signed commits on every branch" needs no exclusion.
# The branch is only ever fast-forwarded by new commits, never force-pushed, so "no force-push" needs none either.
#
#   GH_TOKEN_LIST  token that sees all org repos (fleet-bot, Metadata read)
#   GH_TOKEN       token with contents + pull requests write on $REPO (toolbox-pin App, this repo only)
#   DRY_RUN=1    print the missing repos and the resulting file, change nothing
#   REPO         repository holding fleet/repos.json (default Pascal-Organisation/security-pipeline)
set -euo pipefail

REPO="${REPO:-Pascal-Organisation/security-pipeline}"
BRANCH="bot/fleet-register"
FILE="fleet/repos.json"
DRY_RUN="${DRY_RUN:-0}"
raw() { gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$FILE?ref=$1"; }

main_json="$(raw main)"
ORG="$(jq -r .org <<<"$main_json")"

# Base of the proposal: the open PR's branch (keeps the owner's edits to a stub), else main.
pr="$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
branch_exists=false; gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1 && branch_exists=true
base_json="$main_json"; [ -n "$pr" ] && [ "$branch_exists" = true ] && base_json="$(raw "$BRANCH")"

# Repos of the organisation as the list token sees them (archived and forks excluded here).
candidates="$(GH_TOKEN="${GH_TOKEN_LIST:-$GH_TOKEN}" gh api --paginate "orgs/$ORG/repos?type=all&per_page=100" \
  --jq '.[] | select((.archived | not) and (.fork | not)) | [.name, .visibility] | @tsv')"
[ -n "$candidates" ] || { echo "::error::no repositories listed for $ORG (token without access?)"; exit 1; }

today="$(date -u +%F)"
new_json="$base_json"; missing=()
while IFS=$'\t' read -r name vis; do
  jq -e --arg n "$name" '([.repos[].name] | index($n)) or ((.unmanaged_repos // []) | index($n))' <<<"$new_json" >/dev/null && continue
  missing+=("$name ($vis)")
  # Defaults: profile ci-only (no deploy contract), ring stable (never an early-adopter by accident), standard gate.
  new_json="$(jq --arg n "$name" --arg v "$vis" --arg d "$today" '.repos += [{
      name: $n, profile: "ci-only", ring: "stable", gate_check: "Security / security-gate", visibility: $v,
      todo: true,
      note: ("TODO owner: auto-registered by fleet-register on " + $d + "; confirm profile, ring, gate_check and visibility, then delete the todo and note keys (or list the repo in unmanaged_repos).")
    }]' <<<"$new_json")"
done <<<"$candidates"

if [ "${#missing[@]}" -eq 0 ]; then echo "All non-archived, non-fork repos of $ORG are in $FILE (or already in the open PR): nothing to do."; exit 0; fi
echo "Missing from $FILE: ${missing[*]}"
if [ "$DRY_RUN" = 1 ]; then echo "$new_json" | jq .; exit 0; fi

# A leftover branch without an open PR (merged or closed) starts over from main; with an open PR it is only added to.
if [ "$branch_exists" = true ] && [ -z "$pr" ]; then
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null; branch_exists=false
fi
if [ "$branch_exists" = false ]; then
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)" >/dev/null
fi
blob="$(gh api "repos/$REPO/contents/$FILE?ref=$BRANCH" --jq .sha)"
msg="fleet: register ${missing[*]%% *} (auto, todo)"; [ "${#missing[@]}" -gt 1 ] && msg="fleet: register ${#missing[@]} repos (auto, todo)"
last="$(gh api -X PUT "repos/$REPO/contents/$FILE" -f message="$msg" -f content="$(jq . <<<"$new_json" | base64 -w0)" -f sha="$blob" -f branch="$BRANCH" --jq .commit.sha)"
[ "$(gh api "repos/$REPO/commits/$last" --jq .commit.verification.verified)" = true ] \
  || { echo "::error::commit $last is not verified; the signed-commit rulesets would reject the PR"; exit 1; }

body="$(mktemp)"
{
  echo "Repositories of \`$ORG\` that are neither archived nor forks and are not in \`$FILE\`:"
  echo
  for m in "${missing[@]}"; do echo "- \`$m\`"; done
  echo
  echo "Each got a stub entry with defaults (\`ci-only\`, ring \`stable\`, gate \`Security / security-gate\`) and \`\"todo\": true\`. Before merging, or in a follow-up, the owner confirms profile, ring and gate_check, then removes \`todo\` and \`note\`. A repo that must not be in the fleet goes into \`unmanaged_repos\` instead. \`fleet-drift\` ignores the extra keys and checks the entry like any other (a public repo without the gate check shows up as drift until it is onboarded)."
  echo
  echo "Opened by \`fleet-register.yml\` (fleet-bot App, D-55). The commit is made through the contents API and signed by GitHub. Not auto-merged: a person looks at the stub."
} > "$body"
title="fleet: register new repos (todo)"
if [ -n "$pr" ]; then gh pr edit "$pr" -R "$REPO" --title "$title" --body-file "$body"
else gh pr create -R "$REPO" --base main --head "$BRANCH" --title "$title" --body-file "$body"; fi
