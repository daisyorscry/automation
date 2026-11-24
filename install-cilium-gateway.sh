#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$ROOT_DIR/manifests/cilium-gateway-api"
CILIUM_VERSION=1.19.10
GATEWAY_API_VERSION=v1.4.1
CERT_MANAGER_VERSION=v1.20.4
CLOUDFLARE_API_TOKEN_FILE="${CLOUDFLARE_API_TOKEN_FILE:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( $# == 0 )) || fail 'Usage: bash install-cilium-gateway.sh'
for manifest in cilium-values.yaml lan.yaml namespace.yaml gateway.yaml httproute.yaml; do
  [[ -r "$MANIFEST_DIR/$manifest" ]] || fail "Missing manifest $MANIFEST_DIR/$manifest. Run from a complete checkout."
done

if [[ -n "$CLOUDFLARE_API_TOKEN_FILE" || -n "$ACME_EMAIL" ]]; then
  [[ -f "$CLOUDFLARE_API_TOKEN_FILE" && -r "$CLOUDFLARE_API_TOKEN_FILE" && -s "$CLOUDFLARE_API_TOKEN_FILE" ]] ||
    fail 'Set CLOUDFLARE_API_TOKEN_FILE to a readable, nonempty token file.'
  [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    fail 'Set ACME_EMAIL to a valid ACME contact email.'
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

if [[ -z "$CLOUDFLARE_API_TOKEN_FILE" ]]; then
  log 'Cilium Gateway API and the LAN pool are ready. Set CLOUDFLARE_API_TOKEN_FILE and ACME_EMAIL to install the HTTPS Gateway.'
  exit 0
fi

log 'Prepare cert-manager and the Cloudflare DNS-01 issuer'
cert_manager_crd="$(kubectl get crd certificates.cert-manager.io --ignore-not-found -o name)"
if [[ -z "$cert_manager_crd" ]]; then
  helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --namespace cert-manager --create-namespace --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true --wait --wait-for-jobs --timeout 5m
fi
kubectl wait --for=condition=Established --timeout=120s \
  crd/issuers.cert-manager.io crd/certificates.cert-manager.io
kubectl apply -f "$MANIFEST_DIR/httproute.yaml"
hostname="$(kubectl -n default get httproute app-route -o 'jsonpath={.spec.hostnames[0]}')"
[[ -n "$hostname" && "$hostname" != *.test ]] ||
  fail 'Set a hostname in your Cloudflare zone in httproute.yaml and update the listeners in gateway.yaml.'

kubectl -n cilium-ingress create secret generic cloudflare-dns-token \
  --from-file=api-token=<(tr -d '\r\n' < "$CLOUDFLARE_API_TOKEN_FILE") --dry-run=client -o yaml |
  kubectl apply --server-side -f -

kubectl apply -f - <<MANIFEST
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-dns01
  namespace: cilium-ingress
spec:
  acme:
    email: "$ACME_EMAIL"
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-dns01-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-dns-token
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ingress-tls
  namespace: cilium-ingress
spec:
  secretName: ingress-tls
  dnsNames:
    - "$hostname"
  issuerRef:
    name: letsencrypt-dns01
    kind: Issuer
MANIFEST

log "Wait for Let's Encrypt to issue the certificate"
kubectl -n cilium-ingress wait --for=condition=Ready --timeout=600s certificate/ingress-tls

log 'Install the HTTPS Gateway'
kubectl apply -f "$MANIFEST_DIR/gateway.yaml"
kubectl -n cilium-ingress wait --for=condition=Programmed --timeout=300s gateway/public-gateway
kubectl -n cilium-ingress wait --for='jsonpath={.status.addresses[0].value}' \
  --timeout=120s gateway/public-gateway
kubectl -n cilium-ingress get gateway,svc
