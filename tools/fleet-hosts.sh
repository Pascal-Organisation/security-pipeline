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

# Release commits the hosts may trust as signer: tags from v2.0.0 (the first build-container.yml
# with policy + gate inside) up to TAG, and only if main contains the commit. A tag pushed onto
# an unprotected branch never makes the list.
trusted_list() {
  local name sha status
  gh api "repos/$ORG/security-pipeline/tags" --paginate --jq '.[] | "\(.name) \(.commit.sha)"' |
    while read -r name sha; do
      [[ "$name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
      [ "$(printf '%s\n' v2.0.0 "$name" | sort -V | head -1)" = v2.0.0 ] || continue
      [ "$(printf '%s\n' "$name" "$TAG" | sort -V | head -1)" = "$name" ] || continue
      status="$(gh api "repos/$ORG/security-pipeline/compare/$sha...main" --jq .status)"
      [[ "$status" == ahead || "$status" == identical ]] || { echo "skip $name: not on main" >&2; continue; }
      echo "$sha $name"
    done | sort -k2 -V
}

# Copy to .new, compare hashes, then move: a failed transfer never replaces the file.
push_file() {
  local ct="$1" src="$2" dst="$3" mode="$4" want got
  want="$(sha256sum "$src" | cut -d' ' -f1)"
  ssh -o BatchMode=yes proxmox "LC_ALL=C pct exec $ct -- sh -c 'cat > $dst.new'" < "$src" 2>/dev/null
  got="$(in_ct "$ct" sha256sum "$dst.new" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { echo "CT $ct: hash mismatch, $dst not replaced" >&2; return 1; }
  in_ct "$ct" sh -c "'chown root:root $dst.new && chmod $mode $dst.new && mv $dst.new $dst'"
}

# The trust list goes first: the new deployer refuses to verify without it.
upgrade() {
  local ct="$1"
  in_ct "$ct" install -d -m 0755 /etc/app-deploy
  push_file "$ct" "$TRUSTED" /etc/app-deploy/trusted-pipeline 0644 || return 1
  push_file "$ct" "$DEPLOYER" /usr/local/sbin/app-deploy 0755
}

if [ -n "$TAG" ]; then
  TRUSTED="$(mktemp)"; DEPLOYER="$(mktemp)"
  trap 'rm -f "$TRUSTED" "$DEPLOYER"' EXIT
  { echo "# security-pipeline release commits app-deploy accepts as signer (fleet-hosts --upgrade $TAG)"
    trusted_list; } > "$TRUSTED"
  grep -qE '^[0-9a-f]{40} ' "$TRUSTED" || { echo "no trusted release commits found" >&2; exit 1; }
  grep -E "^[0-9a-f]{40} $TAG\$" "$TRUSTED" >/dev/null || { echo "$TAG is not a trusted release" >&2; exit 1; }
  gh api "repos/$ORG/security-pipeline/contents/deployer/app-deploy?ref=$TAG" --jq .content | base64 -d > "$DEPLOYER"
  bash -n "$DEPLOYER"
fi

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
