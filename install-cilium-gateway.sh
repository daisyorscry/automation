#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$ROOT_DIR/manifests/cilium-gateway-api"
CILIUM_VERSION=1.19.10
GATEWAY_API_VERSION=v1.4.1
source "$ROOT_DIR/lib/cloudflare-dns01.sh"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  ''|--check) ;;
  *) fail 'Usage: bash install-cilium-gateway.sh [--check]' ;;
esac
for manifest in cilium-values.yaml lan.yaml namespace.yaml gateway.yaml httproute.yaml; do
  [[ -r "$MANIFEST_DIR/$manifest" ]] || fail "Missing manifest $MANIFEST_DIR/$manifest. Run from a complete checkout."
done

validate_cloudflare_dns01
if [[ "${1:-}" == --check ]]; then
  exit 0
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
[[ -r "$KUBECONFIG" ]] || fail "Run on the control plane with sudo and a readable $KUBECONFIG."
command -v kubectl >/dev/null || fail 'kubectl is required.'
command -v helm >/dev/null || fail 'Helm is required.'
kubectl --request-timeout=10s get --raw=/readyz >/dev/null

release="$(helm list --namespace kube-system --filter '^cilium$' -o yaml)"
installed_chart="$(awk '$1 == "chart:" {print $2} $1 == "-" && $2 == "chart:" {print $3}' <<< "$release")"
[[ "$installed_chart" == "cilium-$CILIUM_VERSION" ]] ||
  fail "This template expects Cilium $CILIUM_VERSION from init-k8s.sh. Detected chart: ${installed_chart:-none}."

gateway_crd="$(kubectl get crd gateways.gateway.networking.k8s.io --ignore-not-found \
  -o 'jsonpath={.metadata.name}{" "}{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
if [[ -n "$gateway_crd" && "${gateway_crd#* }" != "$GATEWAY_API_VERSION" ]]; then
  fail "Existing Gateway API bundle differs from $GATEWAY_API_VERSION. Check compatibility before changing the shared CRDs."
fi

if [[ "${ALLOW_CONTROL_PLANE_WORKLOADS:-false}" == true ]]; then
  node="$(kubectl get nodes -o name)"
  [[ "$node" == node/* && "$node" != *$'\n'* ]] ||
    fail 'ALLOW_CONTROL_PLANE_WORKLOADS=true requires a single-node cluster.'
  taint="$(kubectl get "$node" -o 'jsonpath={.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}')"
  if [[ "$taint" == NoSchedule ]]; then
    kubectl taint "$node" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
fi

log "Install Gateway API $GATEWAY_API_VERSION"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/grpcroutes.gateway.networking.k8s.io \
  crd/referencegrants.gateway.networking.k8s.io

log "Enable Gateway API and L2 announcements on Cilium $CILIUM_VERSION"
helm upgrade cilium cilium --repo https://helm.cilium.io/ \
  --namespace kube-system --version "$CILIUM_VERSION" --reuse-values --wait --timeout 10m \
  -f "$MANIFEST_DIR/cilium-values.yaml"
kubectl -n kube-system rollout restart deployment/cilium-operator daemonset/cilium
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/cilium
kubectl wait --for=condition=Established --timeout=120s \
  crd/ciliumloadbalancerippools.cilium.io crd/ciliuml2announcementpolicies.cilium.io

log 'Configure the Cilium LAN pool and L2 announcement policy'
kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
kubectl apply -f "$MANIFEST_DIR/lan.yaml"

if ! cloudflare_dns01_requested; then
  log 'Cilium Gateway API and the LAN pool are ready. Set CLOUDFLARE_API_TOKEN and ACME_EMAIL to install the HTTPS Gateway.'
  exit 0
fi

issue_gateway_certificate cilium-ingress "$MANIFEST_DIR/httproute.yaml"

log 'Install the HTTPS Gateway'
kubectl apply -f "$MANIFEST_DIR/gateway.yaml"
kubectl -n cilium-ingress wait --for=condition=Programmed --timeout=300s gateway/public-gateway
kubectl -n cilium-ingress wait --for='jsonpath={.status.addresses[0].value}' \
  --timeout=120s gateway/public-gateway
kubectl -n cilium-ingress get gateway,svc
