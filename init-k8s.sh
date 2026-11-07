#!/usr/bin/env bash
set -Eeuo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32}"
CRIO_VERSION="${CRIO_VERSION:-v1.32}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.10}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.10.232}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CRIO_SOCKET="unix:///var/run/crio/crio.sock"

log() { printf '\n==> %s\n' "$*"; }
trap 'printf "\nERROR: Failed at line %s. Inspect the error above; do not blindly run kubeadm reset.\n" "$LINENO" >&2' ERR

if (( EUID != 0 )); then
  echo 'Run as root: sudo bash init-k8s.sh' >&2
  exit 1
fi

if [[ -e /etc/kubernetes/admin.conf ]]; then
  echo 'This node already has a Kubernetes control plane. Installation aborted to protect the existing cluster.' >&2
  exit 1
fi

if ! ip -4 -o addr show | grep -Fq " $CONTROL_PLANE_IP/"; then
  echo "IP $CONTROL_PLANE_IP is not assigned to this node. Set CONTROL_PLANE_IP to the node's actual IPv4 address." >&2
  exit 1
fi

log 'Configure swap, kernel modules, and sysctl'
swapoff -a
if grep -Eq '^[[:space:]]*[^#[:space:]][^#]*[[:space:]]swap[[:space:]]' /etc/fstab; then
  cp -a /etc/fstab /etc/fstab.k8s.bak
  sed -i -E '/^[[:space:]]*[^#[:space:]][^#]*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
fi

cat > /etc/modules-load.d/k8s.conf <<'MODULES'
overlay
br_netfilter
MODULES
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system > /dev/null

log 'Install package prerequisites'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg iproute2
install -d -m 0755 /etc/apt/keyrings

log 'Configure Kubernetes and CRI-O repositories'
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "$KUBERNETES_VERSION" \
  > /etc/apt/sources.list.d/kubernetes.list

curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/%s/deb/ /\n' "$CRIO_VERSION" \
  > /etc/apt/sources.list.d/cri-o.list

log 'Install CRI-O and Kubernetes components'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y cri-o kubelet kubeadm kubectl
apt-mark hold cri-o kubelet kubeadm kubectl

printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$CONTROL_PLANE_IP" > /etc/default/kubelet
systemctl enable --now crio.service
systemctl enable kubelet.service

log 'Install Helm 3 if needed'
if ! command -v helm >/dev/null 2>&1; then
  HELM_INSTALLER="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$HELM_INSTALLER"
  bash "$HELM_INSTALLER"
  rm -f "$HELM_INSTALLER"
fi

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium
helm show chart cilium/cilium --version "$CILIUM_VERSION" > /dev/null

log 'Initialize the Kubernetes control plane (without kube-proxy)'
kubeadm init \
  --apiserver-advertise-address "$CONTROL_PLANE_IP" \
  --kubernetes-version "$(kubeadm version -o short)" \
  --cri-socket "$CRIO_SOCKET" \
  --skip-phases=addon/kube-proxy

export KUBECONFIG=/etc/kubernetes/admin.conf

log 'Configure kubeconfig for the invoking user'
KUBE_USER="${SUDO_USER:-root}"
KUBE_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
KUBE_GROUP="$(id -gn "$KUBE_USER")"
install -d -m 0700 -o "$KUBE_USER" -g "$KUBE_GROUP" "$KUBE_HOME/.kube"
install -m 0600 -o "$KUBE_USER" -g "$KUBE_GROUP" /etc/kubernetes/admin.conf "$KUBE_HOME/.kube/config"

log "Install Cilium $CILIUM_VERSION (kube-proxy replacement)"
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --wait --timeout 10m \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$CONTROL_PLANE_IP" \
  --set k8sServicePort=6443 \
  --set operator.replicas=1 \
  --set ipam.mode=cluster-pool \
  --set-json "ipam.operator.clusterPoolIPv4PodCIDRList=[\"$POD_CIDR\"]"

log 'Validate the cluster'
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes -o wide
kubectl get pods -n kube-system
kubectl -n kube-system exec daemonset/cilium -- cilium-dbg status --verbose

log 'Installation complete. Worker join command:'
kubeadm token create --print-join-command
