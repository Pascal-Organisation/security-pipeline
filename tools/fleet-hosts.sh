#!/usr/bin/env bash
#
# fleet-hosts — app-deploy on the hosts in fleet/repos.json, reached through `ssh proxmox`.
#   tools/fleet-hosts.sh                 show the installed version per container
#   tools/fleet-hosts.sh --upgrade vX.Y.Z   install app-deploy from that release tag
# The file comes from the local clone's tag, so no host needs access to GitHub for it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/fleet/repos.json"
TAG=""
if [ "${1:-}" = --upgrade ]; then
  TAG="${2:?usage: fleet-hosts.sh --upgrade vX.Y.Z}"
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad tag: $TAG" >&2; exit 2; }
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" > /dev/null || { echo "no local tag $TAG; git fetch --tags" >&2; exit 2; }
fi

jq -r '.repos[] | select(.deployer == "app-deploy") | "\(.name) \(.ct)"' "$MANIFEST" | while read -r name ct; do
  [[ "$ct" =~ ^[0-9]+$ ]] || { echo "$name: bad container id" >&2; exit 2; }
  if [ -n "$TAG" ]; then
    git -C "$ROOT" show "$TAG:deployer/app-deploy" \
      | ssh -o BatchMode=yes proxmox "pct exec $ct -- install -m 0755 /dev/stdin /usr/local/sbin/app-deploy"
  fi
  # Versions before v1.0.0 have no --version and stop with a usage error.
  version="$(ssh -n -o BatchMode=yes proxmox "pct exec $ct -- /usr/local/sbin/app-deploy --version" 2>/dev/null \
    | grep -E '^v[0-9]' || echo 'unversioned (< v1.0.0)')"
  echo "$name (CT $ct): $version"
done
