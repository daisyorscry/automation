#!/usr/bin/env bash
set -Eeuo pipefail

# Reset node Kubernetes lama dan siapkan sebagai worker baru.
# Target: Debian/Ubuntu, Kubernetes + CRI-O v1.32.
# Jalankan: sudo bash reset-to-worker.sh [--yes]

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32}"
CRIO_VERSION="${CRIO_VERSION:-v1.32}"
NODE_NAME="$(hostname -s)"
AUTO_CONFIRM=false

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--yes" && $# -eq 1 ]]; then
  AUTO_CONFIRM=true
elif (( $# != 0 )); then
  fail "Penggunaan: sudo bash $0 [--yes]"
fi

(( EUID == 0 )) || fail "Jalankan sebagai root (sudo)."
[[ -f /etc/debian_version ]] || fail "Script hanya mendukung Debian/Ubuntu."
[[ -d /run/systemd/system ]] || fail "Node harus menggunakan systemd."

IS_CONTROL_PLANE=false
[[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] && IS_CONTROL_PLANE=true
HAS_KUBE_STATE=false
for path in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
            /etc/kubernetes/manifests /var/lib/kubelet/config.yaml; do
  [[ -e "$path" ]] && HAS_KUBE_STATE=true
 done

printf 'Node         : %s\n' "$NODE_NAME"
printf 'State lama   : %s\n' "$HAS_KUBE_STATE"
printf 'Control plane: %s\n' "$IS_CONTROL_PLANE"
printf 'Target       : Kubernetes %s / CRI-O %s (worker)\n' \
  "$KUBERNETES_VERSION" "$CRIO_VERSION"

if [[ "$HAS_KUBE_STATE" == true ]]; then
  printf '\nPERINGATAN: state Kubernetes lokal akan dihapus.\n'
  if [[ "$IS_CONTROL_PLANE" == true ]]; then
    printf 'Node ini adalah CONTROL PLANE. Reset akan menghapus state etcd lokalnya.\n'
    printf 'Jangan jalankan pada satu-satunya control plane cluster yang masih dibutuhkan.\n'
  fi
  if [[ "$AUTO_CONFIRM" != true ]]; then
    read -r -p "Ketik RESET untuk lanjut: " answer
    [[ "$answer" == "RESET" ]] || fail "Dibatalkan."
  fi

  command -v kubeadm >/dev/null 2>&1 || \
    fail "State lama ditemukan tetapi kubeadm tidak ada. Pasang kubeadm lama dahulu."

  log "Menghapus kubeconfig yang identik dengan admin.conf lokal"
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    homes=(/root)
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
      home_dir="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
      [[ -n "$home_dir" ]] && homes+=("$home_dir")
    fi
    for home_dir in "${homes[@]}"; do
      config="$home_dir/.kube/config"
      if [[ -f "$config" ]] && cmp -s /etc/kubernetes/admin.conf "$config"; then
        rm -f -- "$config"
      fi
    done
  fi

  log "kubeadm reset"
  kubeadm reset --force

  # kubeadm reset tidak membersihkan konfigurasi plugin CNI.
  rm -rf -- /etc/cni/net.d /var/lib/cni
  # kubeadm reset umumnya sudah membersihkan direktori ini.
  # Jangan hapus isi /var/lib/kubelet secara paksa: mungkin masih ada mount PV.
  systemctl stop kubelet 2>/dev/null || true
else
  log "Tidak ada state Kubernetes lama; lewati kubeadm reset"
fi

log "Menyiapkan kernel dan swap"
swapoff -a
if [[ -f /etc/fstab ]]; then
  [[ -e /etc/fstab.pre-k8s-worker.bak ]] || \
    cp -p /etc/fstab /etc/fstab.pre-k8s-worker.bak
  awk '{ if ($1 !~ /^#/ && $3 == "swap") print "# " $0; else print }' \
    /etc/fstab > /etc/fstab.k8s-tmp
  cat /etc/fstab.k8s-tmp > /etc/fstab
  rm -f /etc/fstab.k8s-tmp
fi

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-kubernetes.conf

log "Memasang repositori Kubernetes dan CRI-O"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gpg
install -d -m 0755 /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | \
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' \
  "$KUBERNETES_VERSION" > /etc/apt/sources.list.d/kubernetes.list

curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" | \
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/%s/deb/ /\n' \
  "$CRIO_VERSION" > /etc/apt/sources.list.d/cri-o.list
apt-get update

KUBE_PREFIX="${KUBERNETES_VERSION#v}."
CRIO_PREFIX="${CRIO_VERSION#v}."
KUBE_PKG_VERSION="$(apt-cache madison kubeadm | awk -v v="$KUBE_PREFIX" 'index($3, v) == 1 { print $3; exit }')"
CRIO_PKG_VERSION="$(apt-cache madison cri-o | awk -v v="$CRIO_PREFIX" 'index($3, v) == 1 { print $3; exit }')"
[[ -n "$KUBE_PKG_VERSION" ]] || fail "Paket kubeadm ${KUBERNETES_VERSION} tidak tersedia."
[[ -n "$CRIO_PKG_VERSION" ]] || fail "Paket cri-o ${CRIO_VERSION} tidak tersedia."

log "Memasang kubelet/kubeadm/kubectl ${KUBE_PKG_VERSION} + CRI-O ${CRIO_PKG_VERSION}"
apt-mark unhold kubelet kubeadm kubectl cri-o >/dev/null 2>&1 || true
apt-get install -y --allow-downgrades \
  "cri-o=${CRIO_PKG_VERSION}" \
  "kubelet=${KUBE_PKG_VERSION}" \
  "kubeadm=${KUBE_PKG_VERSION}" \
  "kubectl=${KUBE_PKG_VERSION}"
apt-mark hold kubelet kubeadm kubectl cri-o >/dev/null

systemctl enable --now crio.service
systemctl enable kubelet.service
systemctl stop kubelet.service 2>/dev/null || true

log "Validasi"
crio --version
kubeadm version -o short
systemctl is-active crio.service
printf '\nSELESAI: node %s disiapkan sebagai calon worker.\n' "$NODE_NAME"
printf 'Langkah wajib: reboot node sebelum menjalankan kubeadm join.\n'
printf 'Setelah reboot, jalankan perintah join baru dari control plane target,\n'
printf 'dengan tambahan: --cri-socket unix:///var/run/crio/crio.sock\n'
