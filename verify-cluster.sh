#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

gateway_namespace="${GATEWAY_NAMESPACE:-cilium-ingress}"
gateway=gateways.gateway.networking.k8s.io/public-gateway

kubectl get nodes
gateway_class="$(kubectl -n "$gateway_namespace" get "$gateway" -o 'jsonpath={.spec.gatewayClassName}')"
case "$gateway_class" in
  cilium)
    kubectl -n kube-system rollout status daemonset/cilium --timeout=60s
    kubectl get ciliumloadbalancerippools.cilium.io/ingress-lan \
      ciliuml2announcementpolicies.cilium.io/ingress-lan -o name
    ;;
  istio)
    kubectl -n istio-system rollout status deployment/istiod --timeout=60s
    kubectl -n metallb-system rollout status deployment/controller --timeout=60s
    kubectl -n metallb-system rollout status daemonset/speaker --timeout=60s
    kubectl -n metallb-system get ipaddresspools.metallb.io/lan-pool \
      l2advertisements.metallb.io/lan-l2 -o name
    kubectl -n "$gateway_namespace" rollout status deployment/public-gateway-istio --timeout=60s
    ;;
  *) fail "Unsupported GatewayClass: $gateway_class." ;;
esac
kubectl -n "$gateway_namespace" wait --for=condition=Programmed --timeout=60s "$gateway"
gateway_ip="$(kubectl -n "$gateway_namespace" get "$gateway" -o 'jsonpath={.status.addresses[0].value}')"
[[ -n "$gateway_ip" ]] || fail 'The Gateway has no assigned IP.'
hostname="${APP_HOSTNAME:-}"
if [[ -z "$hostname" ]]; then
  hostname="$(kubectl -n "$gateway_namespace" get "$gateway" \
    -o 'jsonpath={.spec.listeners[?(@.name=="https")].hostname}')"
fi
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
  fail 'Set APP_HOSTNAME to a hostname covered by the Gateway TLS certificate.'

name="gateway-smoke-$BASHPID-$RANDOM"
resources=()

cleanup() {
  local status="$?"
  if (( ${#resources[@]} )) &&
    ! kubectl -n default delete --ignore-not-found --timeout=30s "${resources[@]}"; then
    printf 'ERROR: Failed to clean up test resources named %s.\n' "$name" >&2
    (( status != 0 )) || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl -n default create deployment "$name" --image=busybox:1.36 --port=8080 -- \
  sh -ec 'mkdir -p /www; printf "%s\n" "$1" > "/www/$1"; exec httpd -f -p 8080 -h /www' \
  sh "$name"
resources+=("deployment/$name")
kubectl -n default expose deployment "$name" --port=8080
resources+=("service/$name")
kubectl -n default rollout status "deployment/$name" --timeout=180s

kubectl create -f - <<ROUTE
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $name
  namespace: default
spec:
  parentRefs:
    - name: public-gateway
      namespace: "$gateway_namespace"
      sectionName: https
  hostnames:
    - "$hostname"
  rules:
    - matches:
        - path:
            type: Exact
            value: /$name
      backendRefs:
        - name: $name
          port: 8080
ROUTE
resources+=("httproutes.gateway.networking.k8s.io/$name")

response="$(curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  --retry 10 --retry-all-errors --retry-delay 2 \
  --resolve "$hostname:443:$gateway_ip" "https://$hostname/$name")"
[[ "$response" == "$name" ]] || fail 'The HTTPS response did not come from the test workload.'
printf 'HTTPS verified for %s via %s.\n' "$hostname" "$gateway_ip"
