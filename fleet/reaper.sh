#!/usr/bin/env bash
#
# fleet-reaper — cancel zombie workflow runs in every repo of fleet/repos.json.
# A run is a zombie when it is queued, in_progress or waiting and was created more than MAX_AGE_HOURS ago
# (a hosted job lives at most 6 hours, so anything older is stuck). Order: normal cancel; if the API refuses
# or the run is still alive after FORCE_WAIT seconds, force-cancel (the API for runs that never got a runner).
# Needs GH_TOKEN with Actions: write on the fleet repos (the fleet-bot App, fleet/fleet-bot-app.md).
#
#   DRY_RUN=1            list only, cancel nothing
#   MAX_AGE_HOURS=24     age limit (integer >= 1)
#   FORCE_WAIT=180       seconds between cancel and the force-cancel check
#   SELF_REPO / SELF_RUN_ID   never touch the run that executes this script
# Prints a Markdown table; writes cancelled=N and failed=M to $GITHUB_OUTPUT when set. Exit 0 unless a run stays alive.
set -euo pipefail

MANIFEST="$(dirname "$0")/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"
FORCE_WAIT="${FORCE_WAIT:-180}"
DRY_RUN="${DRY_RUN:-0}"
[[ "$MAX_AGE_HOURS" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_AGE_HOURS must be an integer >= 1" >&2; exit 2; }
[[ "$FORCE_WAIT" =~ ^[0-9]+$ ]] || { echo "FORCE_WAIT must be an integer" >&2; exit 2; }
cutoff="$(date -u -d "$MAX_AGE_HOURS hours ago" +%Y-%m-%dT%H:%M:%SZ)"

rows=()       # "repo<TAB>id<TAB>name<TAB>status<TAB>created<TAB>result"
pending=()    # "repo id" of runs cancelled normally, to re-check
cancelled=0; failed=0

record() { rows+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"); }

while read -r repo; do
  for st in queued in_progress waiting; do
    if ! list="$(gh api -X GET "repos/$ORG/$repo/actions/runs" -f status="$st" -f created="<$cutoff" -f per_page=100 --paginate \
        --jq '.workflow_runs[] | [.id, .name, .created_at] | @tsv' 2>&1)"; then
      record "$repo" - - "$st" - "list failed: $(head -c 80 <<<"$list" | tr '\t\n' '  ')"; failed=$((failed + 1)); continue
    fi
    [ -n "$list" ] || continue
    while IFS=$'\t' read -r id name created; do
      [ "$repo/$id" != "${SELF_REPO:-}/${SELF_RUN_ID:-}" ] || continue
      if [ "$DRY_RUN" = 1 ]; then record "$repo" "$id" "$name" "$st" "$created" "would cancel"; continue; fi
      if gh api -X POST "repos/$ORG/$repo/actions/runs/$id/cancel" >/dev/null 2>&1; then
        pending+=("$repo $id"); record "$repo" "$id" "$name" "$st" "$created" "cancel requested"
      elif gh api -X POST "repos/$ORG/$repo/actions/runs/$id/force-cancel" >/dev/null 2>&1; then
        pending+=("$repo $id"); record "$repo" "$id" "$name" "$st" "$created" "force-cancel requested (cancel refused)"
      else
        record "$repo" "$id" "$name" "$st" "$created" "FAILED: cancel and force-cancel refused"; failed=$((failed + 1))
      fi
    done <<<"$list"
  done
done < <(jq -r '.repos[].name' "$MANIFEST")

# Second pass: a run that is still alive after the wait gets force-cancel; then count the outcome.
if [ "${#pending[@]}" -gt 0 ]; then
  sleep "$FORCE_WAIT"
  for p in "${pending[@]}"; do
    read -r repo id <<<"$p"
    status="$(gh api "repos/$ORG/$repo/actions/runs/$id" --jq .status 2>/dev/null || echo unknown)"
    if [ "$status" != completed ]; then
      gh api -X POST "repos/$ORG/$repo/actions/runs/$id/force-cancel" >/dev/null 2>&1 || true
      sleep 15
      status="$(gh api "repos/$ORG/$repo/actions/runs/$id" --jq .status 2>/dev/null || echo unknown)"
    fi
    if [ "$status" = completed ]; then cancelled=$((cancelled + 1)); res="cancelled"
    else failed=$((failed + 1)); res="STILL ALIVE ($status)"; fi
    for i in "${!rows[@]}"; do
      case "${rows[$i]}" in "$repo"$'\t'"$id"$'\t'*) rows[i]="${rows[$i]%$'\t'*}"$'\t'"$res";; esac
    done
  done
fi

echo "Zombie runs older than ${MAX_AGE_HOURS} h (created before $cutoff), org $ORG$([ "$DRY_RUN" = 1 ] && echo ', DRY RUN')"
echo
if [ "${#rows[@]}" -eq 0 ]; then echo "None."; else
  echo "| Repo | Run | Workflow | Status | Created | Result |"
  echo "|---|---|---|---|---|---|"
  for r in "${rows[@]}"; do IFS=$'\t' read -r a b c d e f <<<"$r"; echo "| $a | $b | $c | $d | $e | $f |"; done
fi
echo
echo "cancelled=$cancelled failed=$failed"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "cancelled=$cancelled" >> "$GITHUB_OUTPUT"; echo "failed=$failed" >> "$GITHUB_OUTPUT"; fi
[ "$failed" -eq 0 ]
