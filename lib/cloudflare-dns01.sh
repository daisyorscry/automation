#!/usr/bin/env bash

CERT_MANAGER_VERSION=v1.20.4
cloudflare_api_token="${CLOUDFLARE_API_TOKEN:-}"
unset CLOUDFLARE_API_TOKEN
ACME_EMAIL="${ACME_EMAIL:-}"

cloudflare_dns01_requested() {
  [[ -n "$cloudflare_api_token" ]]
}

validate_cloudflare_dns01() {
  if cloudflare_dns01_requested || [[ -n "$ACME_EMAIL" ]]; then
    cloudflare_dns01_requested || fail 'Set CLOUDFLARE_API_TOKEN for Cloudflare DNS-01.'
    [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
      fail 'Set ACME_EMAIL to a valid ACME contact email.'
  fi
}

issue_gateway_certificate() {
  local gateway_namespace="$1" route_manifest="$2"
  local cert_manager_crd token_data hostname="${GATEWAY_CERT_HOSTNAME:-}"
  log 'Prepare cert-manager and the Cloudflare DNS-01 issuer'
  cert_manager_crd="$(kubectl get crd certificates.cert-manager.io --ignore-not-found -o name)"
  if [[ -z "$cert_manager_crd" ]]; then
    helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
      --namespace cert-manager --create-namespace --version "$CERT_MANAGER_VERSION" \
      --set crds.enabled=true --wait --wait-for-jobs --timeout 5m
  fi
  kubectl wait --for=condition=Established --timeout=120s \
    crd/issuers.cert-manager.io crd/certificates.cert-manager.io
  kubectl apply -f "$route_manifest"
  if [[ -z "$hostname" ]]; then
    hostname="$(kubectl -n default get httproute app-route -o 'jsonpath={.spec.hostnames[0]}')"
  fi
  [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && "$hostname" != *.test ]] ||
    fail 'Use a public hostname in your Cloudflare zone for the Gateway certificate.'

  token_data="$(printf '%s' "$cloudflare_api_token" | base64 -w 0)"
  kubectl apply --server-side -f - <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-dns-token
  namespace: "$gateway_namespace"
type: Opaque
data:
  api-token: "$token_data"
SECRET

  kubectl apply -f - <<MANIFEST
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-dns01
  namespace: "$gateway_namespace"
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
  namespace: "$gateway_namespace"
spec:
  secretName: ingress-tls
  dnsNames:
    - "$hostname"
  issuerRef:
    name: letsencrypt-dns01
    kind: Issuer
MANIFEST

  log "Wait for Let's Encrypt to issue the certificate"
  kubectl -n "$gateway_namespace" wait --for=condition=Ready --timeout=600s certificate/ingress-tls
}
