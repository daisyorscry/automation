#!/usr/bin/env bash
set -Eeuo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32}"
CRIO_VERSION="${CRIO_VERSION:-v1.32}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.10}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.10.232}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CRIO_SOCKET="unix:///var/run/crio/crio.sock"

CURRENT_STAGE='Startup validation'
log() { CURRENT_STAGE="$*"; printf '\n==> %s\n' "$*"; }
wait_for_api() {
  local attempt consecutive=0
  for ((attempt=0; attempt<30; attempt++)); do
    if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then
      consecutive=$((consecutive + 1))
      (( consecutive < 3 )) || return 0
    else
      consecutive=0
    fi
    sleep 2
  done
  echo 'API server did not remain ready for three consecutive checks. Inspect kubelet and CRI-O logs below.' >&2
  return 1
}

refresh_cni_runtime() {
  local attempt
  log 'Wait for Cilium to write the local CNI configuration'
  for ((attempt=0; attempt<300; attempt++)); do
    [[ ! -s /etc/cni/net.d/05-cilium.conflist ]] || break
    sleep 2
  done
  if [[ ! -s /etc/cni/net.d/05-cilium.conflist ]]; then
    echo 'Cilium did not write /etc/cni/net.d/05-cilium.conflist; inspect the Cilium agent logs. Runtime was not restarted.' >&2
    return 1
  fi
  log 'Restart CRI-O and kubelet to load the Cilium CNI configuration'
  systemctl restart crio.service
  systemctl restart kubelet.service
  wait_for_api
}

CLUSTER_DIAGNOSTICS=false
report_failure() {
  local status="$1" line="$2"
  trap - ERR
  printf '\nERROR: Failed at line %s (exit %s).\n' "$line" "$status" >&2
  if [[ "$CLUSTER_DIAGNOSTICS" == true ]]; then
    echo 'Cluster diagnostics (preserving current state):' >&2
    kubectl --request-timeout=10s get nodes -o wide >&2 || true
    kubectl --request-timeout=10s get nodes \
      -o 'custom-columns=NAME:.metadata.name,TAINTS:.spec.taints' >&2 || true
    kubectl --request-timeout=10s -n kube-system get pods -o wide >&2 || true
    kubectl --request-timeout=10s -n kube-system describe pods -l k8s-app=kube-dns >&2 || true
    kubectl --request-timeout=10s -n kube-system get events \
      --field-selector type=Warning --sort-by=.lastTimestamp >&2 || true
    ls -la /etc/cni/net.d/ >&2 || true
    journalctl -u kubelet -u crio -n 50 --no-pager >&2 || true
  fi
  echo 'Inspect the error above; do not blindly run kubeadm reset.' >&2
  printf 'ERROR SUMMARY: stage="%s", line=%s, exit=%s. Send this summary and the original error before Cluster diagnostics.\n' \
    "$CURRENT_STAGE" "$line" "$status" >&2
  exit "$status"
}
trap 'report_failure "$?" "$LINENO"' ERR

if (( EUID != 0 )); then
  echo 'Run as root: sudo bash init-k8s.sh' >&2
  exit 1
fi

GATEWAY_INSTALLER=
CILIUM_HELM_ARGS=(--version "$CILIUM_VERSION" --namespace kube-system --timeout 10m)
case "${1:-}" in
  --with-istio)
    GATEWAY_INSTALLER="$(dirname -- "${BASH_SOURCE[0]}")/install-istio-gateway.sh"
    bash "$GATEWAY_INSTALLER" --check
    CILIUM_HELM_ARGS+=(-f "$(dirname -- "${BASH_SOURCE[0]}")/manifests/istio-gateway-api/cilium-values.yaml")
    ;;
  --with-cilium-gateway)
    GATEWAY_INSTALLER="$(dirname -- "${BASH_SOURCE[0]}")/install-cilium-gateway.sh"
    bash "$GATEWAY_INSTALLER" --check
    ;;
esac

MODE=install
HAS_KUBE_STATE=false
for path in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
            /etc/kubernetes/manifests /var/lib/kubelet/config.yaml; do
  [[ ! -e "$path" ]] || HAS_KUBE_STATE=true
done
if [[ -d /var/lib/etcd ]] && [[ -n "$(find /var/lib/etcd -mindepth 1 -print -quit)" ]]; then
  HAS_KUBE_STATE=true
fi
if command -v ss >/dev/null 2>&1 && \
   [[ -n "$(ss -H -ltn 'sport = :6443 or sport = :10250 or sport = :10257 or sport = :10259 or sport = :2379 or sport = :2380')" ]]; then
  HAS_KUBE_STATE=true
fi

if [[ "$HAS_KUBE_STATE" == true ]]; then
  echo 'Existing Kubernetes state or listening control-plane ports detected.'
  echo 'repair: preserve cluster data, restart services, and reconcile Cilium; skip kubeadm init.'
  echo 'force : DELETE local cluster state, including local etcd, and initialize a new cluster.'
  echo '        Existing workers must rejoin the new cluster.'
  answer=''
  read -r -p 'Choose repair / force / cancel [cancel]: ' answer || true
  case "$answer" in
    repair) MODE=repair ;;
    force)
      confirmation=''
      read -r -p 'Type RESET to delete local cluster state: ' confirmation || true
      if [[ "$confirmation" != RESET ]]; then
        echo 'Installation cancelled.'
        exit 0
      fi
      MODE=force
      ;;
    *) echo 'Installation cancelled.'; exit 0 ;;
  esac
fi

if [[ "$MODE" == repair ]]; then
  for path in /etc/kubernetes/admin.conf /etc/kubernetes/pki/ca.crt \
              /etc/kubernetes/manifests/kube-apiserver.yaml \
              /etc/kubernetes/manifests/kube-controller-manager.yaml \
              /etc/kubernetes/manifests/kube-scheduler.yaml /var/lib/kubelet/config.yaml; do
    if [[ ! -s "$path" ]]; then
      echo "Repair cannot continue: missing $path. Restore the original configuration/PKI from backup, or choose force to rebuild." >&2
      exit 1
    fi
  done
  for command in kubeadm kubectl; do
    command -v "$command" >/dev/null 2>&1 || { echo "Repair requires $command." >&2; exit 1; }
  done
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

if [[ "$MODE" != repair ]]; then
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
fi

if [[ "$MODE" != repair ]]; then
  printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$CONTROL_PLANE_IP" > /etc/default/kubelet
fi
install -d -m 0755 /etc/cni/net.d
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

if [[ "$MODE" == force ]]; then
  log 'Reset local Kubernetes state (force selected and RESET confirmed)'
  kubeadm reset --force --cri-socket "$CRIO_SOCKET"
  systemctl stop kubelet.service
  # Missing manifests can prevent kubeadm from discovering the old local etcd directory.
  rm -rf -- /var/lib/etcd /etc/kubernetes /var/lib/cni
  # Keep the watched directory itself; remove only the old CNI configuration.
  install -d -m 0755 /etc/cni/net.d
  find /etc/cni/net.d -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  REMAINING_PORTS="$(ss -H -ltn 'sport = :6443 or sport = :10250 or sport = :10257 or sport = :10259 or sport = :2379 or sport = :2380')"
  if [[ -n "$REMAINING_PORTS" ]]; then
    echo 'Kubernetes ports are still occupied after reset. Inspect with ss -ltnp before retrying; no preflight checks were bypassed.' >&2
    exit 1
  fi
  systemctl restart crio.service
  systemctl start kubelet.service
fi

if [[ "$MODE" == repair ]]; then
  log 'Repair existing control plane: restart services without kubeadm init'
  systemctl restart crio.service
  systemctl restart kubelet.service
else
  log 'Initialize the Kubernetes control plane (without kube-proxy)'
  kubeadm init \
    --apiserver-advertise-address "$CONTROL_PLANE_IP" \
    --kubernetes-version "$(kubeadm version -o short)" \
    --cri-socket "$CRIO_SOCKET" \
    --skip-phases=addon/kube-proxy
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
CLUSTER_DIAGNOSTICS=true
log 'Wait for a stable API server before installing cluster networking'
wait_for_api

log 'Configure kubeconfig for the invoking user'
KUBE_USER="${SUDO_USER:-root}"
KUBE_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
KUBE_GROUP="$(id -gn "$KUBE_USER")"
install -d -m 0700 -o "$KUBE_USER" -g "$KUBE_GROUP" "$KUBE_HOME/.kube"
install -m 0600 -o "$KUBE_USER" -g "$KUBE_GROUP" /etc/kubernetes/admin.conf "$KUBE_HOME/.kube/config"

if [[ "${ALLOW_CONTROL_PLANE_WORKLOADS:-false}" == true ]]; then
  log 'Allow temporary workloads on the single control-plane node'
  node="$(kubectl get nodes -o name)"
  [[ "$node" == node/* && "$node" != *$'\n'* ]] || {
    echo 'ALLOW_CONTROL_PLANE_WORKLOADS=true requires a single-node cluster.' >&2
    exit 1
  }
  taint="$(kubectl get "$node" -o 'jsonpath={.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}')"
  if [[ "$taint" == NoSchedule ]]; then
    kubectl taint nodes "${node#node/}" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
fi

# Apply the CNI first; validate readiness after CRI-O has loaded its config.
log "Install Cilium $CILIUM_VERSION (kube-proxy replacement)"
if [[ "$MODE" == repair ]]; then
  # Keep the existing endpoint, pod CIDR, and other release-specific settings.
  helm status cilium --namespace kube-system >/dev/null
  helm upgrade cilium cilium/cilium \
    "${CILIUM_HELM_ARGS[@]}" --reuse-values
else
  helm upgrade --install cilium cilium/cilium \
    "${CILIUM_HELM_ARGS[@]}" \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$CONTROL_PLANE_IP" \
    --set k8sServicePort=6443 \
    --set operator.replicas=1 \
    --set ipam.mode=cluster-pool \
    --set-json "ipam.operator.clusterPoolIPv4PodCIDRList=[\"$POD_CIDR\"]"
fi

refresh_cni_runtime

log 'Worker join command (run on workers with sudo and append --cri-socket unix:///var/run/crio/crio.sock)'
kubeadm token create --print-join-command

log 'Validate Cilium, node readiness, and CoreDNS'
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl -n kube-system exec daemonset/cilium -- cilium-dbg status --verbose

log 'Kubernetes networking is ready: Cilium, nodes, and CoreDNS passed readiness checks.'

if [[ -n "${GATEWAY_INSTALLER:-}" ]]; then
  log "Install Gateway components using $(basename -- "$GATEWAY_INSTALLER")"
  bash "$GATEWAY_INSTALLER"
else
  log 'Final cluster status'
  kubectl get nodes -o wide
  kubectl get pods -A -o wide
  log 'Installation complete: Kubernetes and Cilium are ready.'
fi
