#!/usr/bin/env bash
#
# fleet-drift — compare live GitHub settings with the expectations in fleet/repos.json.
# Read-only. Needs a token that may read org Actions settings and repo administration data
# (GH_TOKEN = FLEET_DRIFT_TOKEN, fine-grained read-only: org + repo Administration read). Exit 1 and a list on drift.
set -euo pipefail

MANIFEST="$(dirname "$0")/../fleet/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
drift=()
add() { drift+=("$1"); }

# expect <what> <expected> <actual>
expect() { [ "$2" = "$3" ] || add "$1: expected '$2', found '$3'"; }

# --- org Actions settings -------------------------------------------------------------------
perm="$(gh api "orgs/$ORG/actions/permissions")" || { echo "cannot read org Actions settings (token lacks org Administration: read?)" >&2; exit 2; }
wf="$(gh api "orgs/$ORG/actions/permissions/workflow")"
for k in allowed_actions sha_pinning_required; do
  expect "org $k" "$(jq -r ".org_actions.$k" "$MANIFEST")" "$(jq -r ".$k" <<<"$perm")"
done
for k in default_workflow_permissions can_approve_pull_request_reviews; do
  expect "org $k" "$(jq -r ".org_actions.$k" "$MANIFEST")" "$(jq -r ".$k" <<<"$wf")"
done
if [ "$(jq -r .org_actions.allowed_actions "$MANIFEST")" = selected ]; then
  sel="$(gh api "orgs/$ORG/actions/permissions/selected-actions")"
  for k in github_owned_allowed verified_allowed; do
    expect "org selected-actions $k" "$(jq -r ".org_actions.selected_actions.$k" "$MANIFEST")" "$(jq -r ".$k" <<<"$sel")"
  done
  expect "org selected-actions patterns" \
    "$(jq -c '.org_actions.selected_actions.patterns_allowed | sort' "$MANIFEST")" "$(jq -c '.patterns_allowed | sort' <<<"$sel")"
fi

# --- per repo -------------------------------------------------------------------------------
while read -r entry; do
  repo="$(jq -r .name <<<"$entry")"
  want_vis="$(jq -r .visibility <<<"$entry")"
  if ! info="$(gh api "repos/$ORG/$repo" 2>/dev/null)"; then add "$repo: not readable (renamed, deleted or token scope)"; continue; fi
  expect "$repo visibility" "$want_vis" "$(jq -r .visibility <<<"$info")"
  expect "$repo default workflow permissions" "$(jq -r .org_actions.default_workflow_permissions "$MANIFEST")" \
    "$(gh api "repos/$ORG/$repo/actions/permissions/workflow" --jq .default_workflow_permissions)"

  # Rulesets and code-security features exist only on public repos (GitHub Free).
  [ "$want_vis" = public ] || continue
  for k in secret_scanning secret_scanning_push_protection dependabot_security_updates; do
    expect "$repo $k" "$(jq -r ".security_and_analysis_public.$k" "$MANIFEST")" "$(jq -r ".security_and_analysis.$k.status // \"absent\"" <<<"$info")"
  done
  if [ "$(jq -r '.rulesets == false' <<<"$entry")" != true ]; then
    want="$(jq -c '([.gate_check] + (.extra_required_checks // [])) | sort' <<<"$entry")"
    have="$(gh api "repos/$ORG/$repo/rules/branches/main" \
      | jq -c '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | sort')"
    expect "$repo required checks on main" "$want" "$have"
    gh api "repos/$ORG/$repo/rules/branches/main" | jq -e 'map(.type) | (index("pull_request") != null) and (index("non_fast_forward") != null) and (index("deletion") != null)' >/dev/null \
      || add "$repo main: ruleset lacks pull_request / non_fast_forward / deletion"
  fi
done < <(jq -c '.repos[]' "$MANIFEST")

if [ "${#drift[@]}" -eq 0 ]; then echo "No drift: org and all repos match fleet/repos.json."; exit 0; fi
echo "Drift against fleet/repos.json (${#drift[@]}):"
printf -- '- %s\n' "${drift[@]}"
exit 1
