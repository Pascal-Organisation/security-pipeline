#!/usr/bin/env bash
#
# fleet-rulesets — make the single "security-gate" check required, from fleet/repos.json, and
# (security-pipeline only) protect release tags and every branch (D-51, G-S10).
# Dry run by default; --apply writes. Run it only after the repos' callers are on v1, or the
# required check never reports and every PR there blocks. Private repos on GitHub Free
# answer 403 and are reported as such.
set -euo pipefail

MANIFEST="$(dirname "$0")/../fleet/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
APPLY=false; [ "${1:-}" = --apply ] && APPLY=true
ACTIONS_APP_ID=15368  # the GitHub Actions app: only it may report these checks

branch_ruleset() {
  local contexts="$1" public="$2"  # public repos also get the D-38 rules (signatures, stale reviews, threads, strict checks)
  jq -n --argjson contexts "$contexts" --argjson app "$ACTIONS_APP_ID" --argjson public "$public" '{
    name: "protect main", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"}, {type: "non_fast_forward"},
      {type: "pull_request", parameters: {required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: $public, require_code_owner_review: false,
        require_last_push_approval: false, required_review_thread_resolution: $public}},
      {type: "required_status_checks", parameters: {strict_required_status_checks_policy: $public,
        required_status_checks: ($contexts | map({context: ., integration_id: $app}))}}
    ] + (if $public then [{type: "required_signatures"}] else [] end)}'
}

tag_ruleset() {
  jq -n '{
    name: "protect release tags", target: "tag", enforcement: "active",
    conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
    rules: [{type: "deletion"}, {type: "non_fast_forward"}, {type: "update"}, {type: "required_signatures"}]}'
}

# G-S10 / D-51: every branch needs signed commits (also unmerged ones: a signature on any branch
# must mean something). No bypass actors. Deletion is not blocked (merged branches are deleted).
signed_branches_ruleset() {
  jq -n '{
    name: "signed commits on every branch", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~ALL"], exclude: []}},
    rules: [{type: "required_signatures"}]}'
}

# No force-push on any branch except the two bot-owned kinds that are rewritten by design:
# Renovate rebases renovate/** and the pin job resets bot/toolbox-pin to main (toolbox.yml,
# PATCH force=true). Both stay covered by signed_branches_ruleset.
no_force_push_ruleset() {
  jq -n '{
    name: "no force-push on branches", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~ALL"],
      exclude: ["refs/heads/renovate/**", "refs/heads/bot/toolbox-pin"]}},
    rules: [{type: "non_fast_forward"}]}'
}

upsert() {
  local repo="$1" body="$2" name id
  name="$(jq -r .name <<<"$body")"
  if ! id="$(gh api "repos/$ORG/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null)"; then
    echo "$repo: '$name' not possible (private repo on GitHub Free)"; return 0
  fi
  if ! $APPLY; then
    echo "$repo: would $([ -n "$id" ] && echo update || echo create) '$name': $(jq -c '{rules: [.rules[].type], include: .conditions.ref_name.include, exclude: .conditions.ref_name.exclude, checks: [.rules[] | .parameters.required_status_checks[]?.context]}' <<<"$body")"
    return 0
  fi
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input - <<<"$body" > /dev/null
  else
    gh api -X POST "repos/$ORG/$repo/rulesets" --input - <<<"$body" > /dev/null
  fi
  echo "$repo: '$name' applied"
}

jq -c '.repos[]' "$MANIFEST" | while read -r entry; do
  repo="$(jq -r .name <<<"$entry")"
  if [ "$(jq -r '.rulesets == false' <<<"$entry")" = true ]; then
    echo "$repo: skipped (rulesets: false in the manifest)"; continue
  fi
  public=false; [ "$(jq -r '.visibility' <<<"$entry")" = public ] && public=true
  upsert "$repo" "$(branch_ruleset "$(jq -c '[.gate_check] + (.extra_required_checks // [])' <<<"$entry")" "$public")"
  if [ "$repo" = security-pipeline ]; then
    upsert "$repo" "$(tag_ruleset)"
    upsert "$repo" "$(signed_branches_ruleset)"
    upsert "$repo" "$(no_force_push_ruleset)"
  fi
done
