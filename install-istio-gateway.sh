#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$ROOT_DIR/manifests/istio-gateway-api"
ISTIO_VERSION=1.31.4
GATEWAY_API_VERSION=v1.6.0
METALLB_VERSION=v0.15.2
GATEWAY_TLS_CERT="${GATEWAY_TLS_CERT:-}"
GATEWAY_TLS_KEY="${GATEWAY_TLS_KEY:-}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for manifest in metallb.yaml namespace.yaml gateway.yaml httproute.yaml; do
  [[ -r "$MANIFEST_DIR/$manifest" ]] || fail "Missing manifest $MANIFEST_DIR/$manifest. Run from a complete checkout."
done

if [[ -n "$GATEWAY_TLS_CERT" || -n "$GATEWAY_TLS_KEY" ]]; then
  [[ -n "$GATEWAY_TLS_CERT" && -f "$GATEWAY_TLS_CERT" && -r "$GATEWAY_TLS_CERT" ]] ||
    fail 'Set GATEWAY_TLS_CERT to a readable certificate file.'
  [[ -n "$GATEWAY_TLS_KEY" && -f "$GATEWAY_TLS_KEY" && -r "$GATEWAY_TLS_KEY" ]] ||
    fail 'Set GATEWAY_TLS_KEY to a readable private key file.'
fi

case "${1:-}" in
  --check) exit 0 ;;
  '') ;;
  *) fail 'Usage: bash install-istio-gateway.sh [--check]' ;;
esac

export KUBECONFIG=/etc/kubernetes/admin.conf
[[ -r "$KUBECONFIG" ]] || fail "Run on the control plane with sudo and a readable $KUBECONFIG."
command -v kubectl >/dev/null || fail 'kubectl is required.'
command -v helm >/dev/null || fail 'Helm is required.'
kubectl --request-timeout=10s get --raw=/readyz >/dev/null

if [[ "${ALLOW_CONTROL_PLANE_WORKLOADS:-false}" == true ]]; then
  node="$(kubectl get nodes -o name)"
  [[ "$node" == node/* && "$node" != *$'\n'* ]] ||
    fail 'ALLOW_CONTROL_PLANE_WORKLOADS=true requires a single-node cluster.'
  taint="$(kubectl get "$node" -o 'jsonpath={.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}')"
  if [[ "$taint" == NoSchedule ]]; then
    log "Allow workloads on $node"
    kubectl taint "$node" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
  kubectl label "$node" node.kubernetes.io/exclude-from-external-load-balancers-
fi

log "Install Gateway API $GATEWAY_API_VERSION"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io

log "Install MetalLB $METALLB_VERSION and its LAN pool"
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
kubectl wait --for=condition=Established --timeout=120s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl -n metallb-system rollout status deployment/controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s
kubectl apply -f "$MANIFEST_DIR/metallb.yaml"

log "Install Istio $ISTIO_VERSION"
ISTIO_REPO=https://blob.istio.io/istio-release/charts
helm upgrade --install istio-base base --repo "$ISTIO_REPO" \
  --namespace istio-system --create-namespace --version "$ISTIO_VERSION" \
  --set defaultRevision=default --wait --timeout 5m
helm upgrade --install istiod istiod --repo "$ISTIO_REPO" \
  --namespace istio-system --version "$ISTIO_VERSION" --wait --timeout 5m
kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/istio

if [[ -z "$GATEWAY_TLS_CERT" ]]; then
  log 'Istio and MetalLB are ready. Set GATEWAY_TLS_CERT and GATEWAY_TLS_KEY to install the HTTPS Gateway and routes.'
  exit 0
fi

log 'Install the HTTPS Gateway and routes'
kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
kubectl -n istio-ingress create secret tls ingress-tls \
  --cert="$GATEWAY_TLS_CERT" --key="$GATEWAY_TLS_KEY" --dry-run=client -o yaml |
  kubectl apply --server-side -f -
kubectl apply -f "$MANIFEST_DIR/gateway.yaml"
kubectl apply -f "$MANIFEST_DIR/httproute.yaml"
kubectl -n istio-ingress wait --for=condition=Programmed --timeout=300s gateway/public-gateway
kubectl -n istio-ingress rollout status deployment/public-gateway-istio --timeout=300s
kubectl -n istio-ingress wait --for='jsonpath={.status.loadBalancer.ingress[0].ip}' \
  --timeout=120s service/public-gateway-istio
kubectl -n istio-ingress get service public-gateway-istio
