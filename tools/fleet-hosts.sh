#!/usr/bin/env bash
#
# fleet-hosts — what the hosts in fleet/repos.json actually run, through `ssh proxmox`.
#   tools/fleet-hosts.sh                    one row per app: version, last check, running vs latest
#   tools/fleet-hosts.sh --upgrade vX.Y.Z   install app-deploy from that release tag first
# A release being green says nothing about the host; this is the check that does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/fleet/repos.json"
ORG="$(jq -r .org "$MANIFEST")"
TAG=""
if [ "${1:-}" = --upgrade ]; then
  TAG="${2:?usage: fleet-hosts.sh --upgrade vX.Y.Z}"
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad tag: $TAG" >&2; exit 2; }
fi

in_ct() { local ct="$1"; shift; ssh -n -o BatchMode=yes proxmox "LC_ALL=C pct exec $ct -- $*" 2>/dev/null; }

# Copy to .new, compare hashes, then move: a failed transfer never replaces the deployer.
upgrade() {
  local ct="$1" tmp want got
  tmp="$(mktemp)"
  gh api "repos/$ORG/security-pipeline/contents/deployer/app-deploy?ref=$TAG" --jq .content | base64 -d > "$tmp"
  want="$(sha256sum "$tmp" | cut -d' ' -f1)"
  ssh -o BatchMode=yes proxmox "LC_ALL=C pct exec $ct -- sh -c 'cat > /usr/local/sbin/app-deploy.new'" < "$tmp" 2>/dev/null
  got="$(in_ct "$ct" sha256sum /usr/local/sbin/app-deploy.new | cut -d' ' -f1)"
  rm -f "$tmp"
  [ "$want" = "$got" ] || { echo "CT $ct: hash mismatch, deployer not replaced" >&2; return 1; }
  in_ct "$ct" sh -c "'chmod 0755 /usr/local/sbin/app-deploy.new && mv /usr/local/sbin/app-deploy.new /usr/local/sbin/app-deploy'"
}

latest() { # digest of :latest, or ? for a private image we cannot read anonymously
  local token
  token="$(curl -sS -m 15 "https://ghcr.io/token?scope=repository:$1:pull" | jq -r '.token // empty')"
  [ -n "$token" ] || { echo "?"; return; }
  curl -sS -m 15 -o /dev/null -D - -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$1/manifests/latest" | tr -d '\r' | sed -n 's/^docker-content-digest: //Ip' | grep . || echo "?"
}

echo "| App | CT | app-deploy | Letzte Prüfung | Ergebnis | Läuft | Neueste Version |"
echo "|---|---|---|---|---|---|---|"
jq -r '.repos[] | select(.deployer == "app-deploy") | "\(.name) \(.app) \(.ct)"' "$MANIFEST" | while read -r name app ct; do
  [[ "$ct" =~ ^[0-9]+$ && "$app" =~ ^[a-z0-9-]+$ ]] || { echo "$name: bad manifest entry" >&2; continue; }
  [ -z "$TAG" ] || upgrade "$ct" || continue
  version="$(in_ct "$ct" /usr/local/sbin/app-deploy --version | grep -E '^v[0-9]' || echo 'nicht installiert')"
  status="$(in_ct "$ct" cat "/var/lib/app-deploy/$app.json" || true)"
  [ -n "$status" ] || status='{}'
  running="$(jq -r '.running // "" | sub(".*@sha256:"; "") | .[:12]' <<<"$status")"
  want="$(latest "pascal-organisation/${name,,}" | sed 's/^sha256://' | cut -c1-12)"
  result="$(jq -r 'if .ok == true then "ok" elif .ok == false then "FEHLER: \(.error)" else "–" end' <<<"$status")"
  echo "| $name | $ct | $version | $(jq -r '.checked // "–"' <<<"$status") | $result | ${running:-–} | ${want:-?} |"
done
