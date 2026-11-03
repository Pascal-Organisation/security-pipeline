#!/usr/bin/env bash
#
# node-install.sh — single-node k3s for GitHub Actions Runner Controller (run as root on the node VM).
#
# Installs, all pinned and checksum-verified:
#   k3s  (binary from the GitHub release, checked against its sha256sum-amd64.txt)
#   helm (tarball from get.helm.sh, checked against its .sha256sum)
# k3s config: no traefik/servicelb (nothing is served), secrets encrypted at rest (the GitHub App
# key lives in a Secret), kubeconfig root-only. Kata Containers and ARC are installed with helm
# afterwards (README.md).
set -euo pipefail

K3S_VERSION="v1.36.5+k3s1"
HELM_VERSION="v4.3.1"
HELM_SHA256="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "== packages"
command -v cloud-init >/dev/null && cloud-init status --wait >/dev/null || true
apt-get -o DPkg::Lock::Timeout=600 update -q
apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends \
  curl ca-certificates jq qemu-guest-agent unattended-upgrades zstd
systemctl enable --now qemu-guest-agent
[ -e /dev/kvm ] || { echo "no /dev/kvm: Kata needs nested virtualization (cpu: host)" >&2; exit 1; }

echo "== k3s $K3S_VERSION"
rel="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"
curl -fsSL -o "$tmp/k3s" "$rel/k3s"
curl -fsSL -o "$tmp/sha256sum-amd64.txt" "$rel/sha256sum-amd64.txt"
( cd "$tmp" && grep -E ' k3s$' sha256sum-amd64.txt | sha256sum -c - )
install -m 0755 "$tmp/k3s" /usr/local/bin/k3s
curl -fsSL -o "$tmp/install.sh" "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh"
install -d -m 0700 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'EOF'
write-kubeconfig-mode: "0600"
secrets-encryption: true
disable:
  - traefik
  - servicelb
kubelet-arg:
  - "max-pods=60"
EOF
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION="$K3S_VERSION" sh "$tmp/install.sh" >/dev/null
for _ in $(seq 1 60); do k3s kubectl get node 2>/dev/null | grep -q ' Ready ' && break; sleep 5; done
k3s kubectl get node

echo "== helm $HELM_VERSION"
curl -fsSL -o "$tmp/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
echo "${HELM_SHA256}  $tmp/helm.tgz" | sha256sum -c -
tar -xzf "$tmp/helm.tgz" -C "$tmp" linux-amd64/helm
install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
grep -q KUBECONFIG /root/.bashrc || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc
helm version --short
echo "ok"
