#!/usr/bin/env bash

CERT_MANAGER_VERSION=v1.20.4
CLOUDFLARE_API_TOKEN_FILE="${CLOUDFLARE_API_TOKEN_FILE:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

validate_cloudflare_dns01() {
  if [[ -n "$CLOUDFLARE_API_TOKEN_FILE" || -n "$ACME_EMAIL" ]]; then
    [[ -f "$CLOUDFLARE_API_TOKEN_FILE" && -r "$CLOUDFLARE_API_TOKEN_FILE" && -s "$CLOUDFLARE_API_TOKEN_FILE" ]] ||
      fail 'Set CLOUDFLARE_API_TOKEN_FILE to a readable, nonempty token file.'
    [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
      fail 'Set ACME_EMAIL to a valid ACME contact email.'
  fi
}

issue_gateway_certificate() {
  local gateway_namespace="$1" route_manifest="$2"
  local cert_manager_crd hostname
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
  hostname="$(kubectl -n default get httproute app-route -o 'jsonpath={.spec.hostnames[0]}')"
  [[ -n "$hostname" && "$hostname" != *.test ]] ||
    fail 'Set a hostname in your Cloudflare zone in httproute.yaml and update the listeners in gateway.yaml.'

  kubectl -n "$gateway_namespace" create secret generic cloudflare-dns-token \
    --from-file=api-token=<(tr -d '\r\n' < "$CLOUDFLARE_API_TOKEN_FILE") --dry-run=client -o yaml |
    kubectl apply --server-side -f -

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
