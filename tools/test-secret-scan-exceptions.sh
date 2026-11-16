#!/usr/bin/env bash
# Tests for the TruffleHog exception kind "secret-scan" (D-48). The jq programs are taken from the
# marked blocks of .github/workflows/ci.yml, so the test runs the code the pipeline runs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ci="$root/.github/workflows/ci.yml"
for name in validate filter; do
  # shellcheck disable=SC1090
  source <(sed -n "/# BEGIN secret-scan-$name/,/# END secret-scan-$name/p" "$ci" | sed 's/^ *//')
done
[ -n "${validate:-}" ] && [ -n "${filter:-}" ] || { echo "markers not found in ci.yml"; exit 1; }

C1=1111111111111111111111111111111111111111
C2=2222222222222222222222222222222222222222
today="$(date -u +%F)"; future="$(date -u -d '+30 days' +%F)"; past="$(date -u -d '-1 day' +%F)"; toolong="$(date -u -d '+91 days' +%F)"
max="$(date -u -d '+90 days' +%F)"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

finding() { # detector file commit line verified
  jq -nc --arg d "$1" --arg f "$2" --arg c "$3" --argjson l "$4" --argjson v "$5" \
    '{DetectorName: $d, Verified: $v, SourceMetadata: {Data: {Git: {file: $f, commit: $c, line: $l}}}}'
}
entry() { # expires [extra jq object]
  jq -nc --arg e "$1" --argjson x "${2:-{\}}" \
    '{id: "x-1", kind: "secret-scan", detector: "JDBC", path: "deploy/app.yaml", commit: "'"$C1"'", reason: "test", owner: "o", expires: $e} + $x'
}
remaining() { # exceptions-array finding -> number of findings left
  printf '%s\n' "$2" | jq -c --argjson exc "$1" "$filter" | wc -l
}
active() { jq -c --arg t "$today" '[.[] | select(.expires >= $t)]' <<<"[$1]"; }

f="$(finding JDBC deploy/app.yaml $C1 95 false)"
[ "$(remaining "$(active "$(entry "$future")")" "$f")" = 0 ] && ok "matching entry suppresses" || bad "matching entry suppresses"
[ "$(remaining "$(active "$(entry "$past")")" "$f")" = 1 ] && ok "expired entry does not suppress" || bad "expired entry does not suppress"
fv="$(finding JDBC deploy/app.yaml $C1 95 true)"
[ "$(remaining "$(active "$(entry "$future")")" "$fv")" = 1 ] && ok "verified finding is never suppressed" || bad "verified finding is never suppressed"
[ "$(remaining "$(active "$(entry "$future")")" "$(finding JDBC deploy/app.yaml $C2 95 false)")" = 1 ] && ok "wrong commit does not match" || bad "wrong commit does not match"
[ "$(remaining "$(active "$(entry "$future")")" "$(finding JDBC deploy/other.yaml $C1 95 false)")" = 1 ] && ok "wrong path does not match" || bad "wrong path does not match"
[ "$(remaining "$(active "$(entry "$future")")" "$(finding AWS deploy/app.yaml $C1 95 false)")" = 1 ] && ok "wrong detector does not match" || bad "wrong detector does not match"
[ "$(remaining "$(active "$(entry "$future" '{"line": 95}')")" "$f")" = 0 ] && ok "entry with line matches that line" || bad "entry with line matches that line"
[ "$(remaining "$(active "$(entry "$future" '{"line": 12}')")" "$f")" = 1 ] && ok "entry with another line does not match" || bad "entry with another line does not match"
[ "$(remaining '[]' "$f")" = 1 ] && ok "no exceptions: finding blocks" || bad "no exceptions: finding blocks"

valid() { printf '{"exceptions":[%s]}' "$1" | jq -e --arg max "$max" "$validate" > /dev/null 2>&1; }
valid "$(entry "$future")" && ok "valid entry passes validation" || bad "valid entry passes validation"
valid "$(entry "$toolong")" && bad "expiry beyond 90 days is rejected" || ok "expiry beyond 90 days is rejected"
valid "$(entry "$future" '{"path": "deploy/*.yaml"}')" && bad "path glob is rejected" || ok "path glob is rejected"
valid "$(entry "$future" '{"commit": "abc123"}')" && bad "short commit is rejected" || ok "short commit is rejected"
valid "$(entry "$future" '{"owner": ""}')" && bad "empty owner is rejected" || ok "empty owner is rejected"
valid "$(entry "$future" '{"detector": ""}')" && bad "empty detector is rejected" || ok "empty detector is rejected"
valid "$(entry "$future" '{"kind": "vulnerability", "owner": ""}')" && ok "other kinds are not touched by this check" || bad "other kinds are not touched by this check"

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all tests passed"
