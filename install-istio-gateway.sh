#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$ROOT_DIR/manifests/istio-gateway-api"
ISTIO_VERSION=1.31.4
GATEWAY_API_VERSION=v1.6.0
METALLB_VERSION=v0.15.2
source "$ROOT_DIR/lib/cloudflare-dns01.sh"
source "$ROOT_DIR/lib/istio-ambient.sh"
GATEWAY_TLS_CERT="${GATEWAY_TLS_CERT:-}"
GATEWAY_TLS_KEY="${GATEWAY_TLS_KEY:-}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mode="${1:-}"
case "$mode" in
  ''|--check|--gateway-only) ;;
  *) fail 'Usage: bash install-istio-gateway.sh [--check|--gateway-only]' ;;
esac

manifests=(namespace.yaml gateway.yaml httproute.yaml)
if [[ "$mode" != --gateway-only ]]; then
  manifests+=(metallb.yaml peer-authentication.yaml waypoint.yaml)
  validate_ambient_settings
fi
for manifest in "${manifests[@]}"; do
  [[ -r "$MANIFEST_DIR/$manifest" ]] || fail "Missing manifest $MANIFEST_DIR/$manifest. Run from a complete checkout."
done

validate_cloudflare_dns01

if [[ -n "$GATEWAY_TLS_CERT" || -n "$GATEWAY_TLS_KEY" ]]; then
  if cloudflare_dns01_requested; then
    fail 'Choose Cloudflare DNS-01 or certificate files for TLS.'
  fi
  [[ -n "$GATEWAY_TLS_CERT" && -f "$GATEWAY_TLS_CERT" && -r "$GATEWAY_TLS_CERT" ]] ||
    fail 'Set GATEWAY_TLS_CERT to a readable certificate file.'
  [[ -n "$GATEWAY_TLS_KEY" && -f "$GATEWAY_TLS_KEY" && -r "$GATEWAY_TLS_KEY" ]] ||
    fail 'Set GATEWAY_TLS_KEY to a readable private key file.'
fi

if [[ "$mode" == --check ]]; then
  exit 0
fi
if [[ "$mode" == --gateway-only ]] && ! cloudflare_dns01_requested && [[ -z "$GATEWAY_TLS_CERT" ]]; then
  fail 'Set CLOUDFLARE_API_TOKEN and ACME_EMAIL to install the HTTPS Gateway.'
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
[[ -r "$KUBECONFIG" ]] || fail "Run on the control plane with sudo and a readable $KUBECONFIG."
command -v kubectl >/dev/null || fail 'kubectl is required.'
command -v helm >/dev/null || fail 'Helm is required.'
kubectl --request-timeout=10s get --raw=/readyz >/dev/null

if [[ "$mode" == --gateway-only ]]; then
  source "$ROOT_DIR/lib/ipv4.sh"
  pool_addresses="$(kubectl -n metallb-system get ipaddresspool.metallb.io lan-pool \
    -o 'jsonpath={range .spec.addresses[*]}{.}{"\n"}{end}')" ||
    fail 'Unable to read MetalLB pool lan-pool. Run the Istio control-plane bootstrap first.'
  requested_ip="$(kubectl create --dry-run=client -f "$MANIFEST_DIR/gateway.yaml" \
    -o 'jsonpath={.spec.infrastructure.annotations.metallb\.io/loadBalancerIPs}')"
  if [[ -n "$requested_ip" ]]; then
    requested_address="$(ipv4_number "$requested_ip")" ||
      fail 'Set an IPv4 address in the Gateway metallb.io/loadBalancerIPs annotation.'
    in_pool=false
    while IFS= read -r block; do
      if ipv4_in_block "$requested_address" "$block"; then
        in_pool=true
        break
      fi
    done <<< "$pool_addresses"
    [[ "$in_pool" == true ]] || fail "Gateway IP $requested_ip is outside the existing MetalLB pool lan-pool."
  fi
else
  preflight_ambient_namespaces
  if [[ "${ALLOW_CONTROL_PLANE_WORKLOADS:-false}" == true ]]; then
    node="$(kubectl get nodes -o name)"
    [[ "$node" == node/* && "$node" != *$'\n'* ]] ||
      fail 'ALLOW_CONTROL_PLANE_WORKLOADS=true requires a single-node cluster.'
    taint="$(kubectl get "$node" -o 'jsonpath={.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}')"
    if [[ "$taint" == NoSchedule ]]; then
      log "Allow workloads on $node"
      kubectl taint nodes "${node#node/}" node-role.kubernetes.io/control-plane:NoSchedule-
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

  ISTIO_REPO=https://blob.istio.io/istio-release/charts
  configure_ambient_cilium
  install_ambient_components
  enroll_ambient_namespaces
fi
kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/istio

if ! cloudflare_dns01_requested && [[ -z "$GATEWAY_TLS_CERT" ]]; then
  log 'Istio ambient mesh, STRICT mTLS, and MetalLB are ready. Set CLOUDFLARE_API_TOKEN and ACME_EMAIL to install the HTTPS Gateway.'
  exit 0
fi

log 'Install the HTTPS Gateway and routes'
kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
if cloudflare_dns01_requested; then
  issue_gateway_certificate istio-ingress "$MANIFEST_DIR/httproute.yaml"
else
  kubectl -n istio-ingress create secret tls ingress-tls \
    --cert="$GATEWAY_TLS_CERT" --key="$GATEWAY_TLS_KEY" --dry-run=client -o yaml |
    kubectl apply --server-side -f -
  kubectl apply -f "$MANIFEST_DIR/httproute.yaml"
fi
kubectl apply -f "$MANIFEST_DIR/gateway.yaml"
kubectl -n istio-ingress wait --for=condition=Programmed --timeout=300s gateways.gateway.networking.k8s.io/public-gateway
kubectl -n istio-ingress rollout status deployment/public-gateway-istio --timeout=300s
kubectl -n istio-ingress wait --for='jsonpath={.status.loadBalancer.ingress[0].ip}' \
  --timeout=120s service/public-gateway-istio
kubectl -n istio-ingress get service public-gateway-istio
