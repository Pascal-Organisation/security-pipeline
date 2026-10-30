#!/usr/bin/env bash
#
# fleet-rulesets — make the single "security-gate" check required, from fleet/repos.json.
# Dry run by default; --apply writes. Run it only after the repos' callers are on v1, or the
# required check never reports and every PR there blocks. Private repos on GitHub Free
# answer 403 and are reported as such.
set -euo pipefail

MANIFEST="$(dirname "$0")/../fleet/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
APPLY=false; [ "${1:-}" = --apply ] && APPLY=true
ACTIONS_APP_ID=15368  # the GitHub Actions app: only it may report these checks

branch_ruleset() {
  local contexts="$1"
  jq -n --argjson contexts "$contexts" --argjson app "$ACTIONS_APP_ID" '{
    name: "protect main", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"}, {type: "non_fast_forward"},
      {type: "pull_request", parameters: {required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false, require_code_owner_review: false,
        require_last_push_approval: false, required_review_thread_resolution: false}},
      {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
        required_status_checks: ($contexts | map({context: ., integration_id: $app}))}}
    ]}'
}

tag_ruleset() {
  jq -n '{
    name: "protect release tags", target: "tag", enforcement: "active",
    conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
    rules: [{type: "deletion"}, {type: "non_fast_forward"}, {type: "update"}]}'
}

upsert() {
  local repo="$1" body="$2" name id
  name="$(jq -r .name <<<"$body")"
  if ! id="$(gh api "repos/$ORG/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null)"; then
    echo "$repo: '$name' not possible (private repo on GitHub Free)"; return 0
  fi
  if ! $APPLY; then
    echo "$repo: would $([ -n "$id" ] && echo update || echo create) '$name': $(jq -c '[.rules[] | .parameters.required_status_checks[]?.context]' <<<"$body")"
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
  if [ "$(jq -r '.rulesets // true' <<<"$entry")" = false ]; then
    echo "$repo: skipped (rulesets: false in the manifest)"; continue
  fi
  upsert "$repo" "$(branch_ruleset "$(jq -c '[.gate_check] + (.extra_required_checks // [])' <<<"$entry")")"
  [ "$repo" = security-pipeline ] && upsert "$repo" "$(tag_ruleset)"
done
