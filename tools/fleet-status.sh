#!/usr/bin/env bash
#
# fleet-status — what every repo in fleet/repos.json actually runs, as a Markdown table.
# Read-only, uses your own `gh` login, needs no credential in CI. Replaces hand-kept tables.
set -euo pipefail

MANIFEST="$(dirname "$0")/../fleet/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
latest="$(gh api "repos/$ORG/security-pipeline/releases/latest" --jq .tag_name 2>/dev/null || echo '?')"

# Pipeline versions pinned on a ref, from the "# vX.Y.Z" comments of all workflow files.
pins() {
  local repo="$1" ref="$2" f
  gh api "repos/$ORG/$repo/contents/.github/workflows?ref=$ref" --jq '.[].name' 2>/dev/null | while read -r f; do
    gh api "repos/$ORG/$repo/contents/.github/workflows/$f?ref=$ref" --jq .content | base64 -d \
      | grep -E 'security-pipeline/\.github/workflows/.*@' | grep -oE '# v[0-9.]+' | cut -c3- || true
  done | sort -u | paste -sd, -
}

echo "Latest release: **$latest**"
echo
echo "| Repo | Profil | Ring | Pin auf main | Offene Rollout-PRs | Letzter Lauf auf main | Gate Pflicht? | Hinweis |"
echo "|---|---|---|---|---|---|---|---|"
jq -c '.repos[]' "$MANIFEST" | while read -r entry; do
  repo="$(jq -r .name <<<"$entry")"
  pin="$(pins "$repo" main)"
  [ "$repo" = security-pipeline ] && pin="(lokal)"
  [ -n "$pin" ] || pin="–"
  [ "$pin" = "$latest" ] && pin="**$pin**"
  prs="$(gh pr list -R "$ORG/$repo" --state open --search 'security-pipeline in:title,head' \
        --json number --jq 'map("#\(.number)") | join(" ")')"
  run="$(gh run list -R "$ORG/$repo" --branch main --limit 1 --json workflowName,conclusion,createdAt \
        --jq '.[0] | if . == null then "–" else "\(.workflowName): \(.conclusion // "läuft") (\(.createdAt[:10]))" end')"
  check="$(jq -r .gate_check <<<"$entry")"
  # 403 on GitHub Free for private repos: nothing can be required there.
  required="$(gh api "repos/$ORG/$repo/rules/branches/main" 2>/dev/null \
        | jq -r --arg c "$check" '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]
                                   | if index($c) then "ja" else "nein" end' 2>/dev/null || echo "n/a")"
  note="$(jq -r '.note // ""' <<<"$entry")"
  echo "| \`$repo\` | $(jq -r .profile <<<"$entry") | $(jq -r .ring <<<"$entry") | $pin | ${prs:-–} | $run | ${required:-n/a} | $note |"
done
