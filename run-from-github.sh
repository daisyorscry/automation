#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run this installer with sudo.'
(( $# == 1 )) || fail 'Choose init-cilium-gateway, init-istio-gateway, init-istio, gateway-istio, or gateway-cilium.'

case "$1" in
  init-istio|init-istio-gateway|gateway-istio)
    installer=install-istio-gateway.sh
    template=istio-gateway-api
    ;;
  init-cilium-gateway|gateway-cilium)
    installer=install-cilium-gateway.sh
    template=cilium-gateway-api
    ;;
  *) fail "Unknown installer: $1" ;;
esac

ref="${AUTOMATION_REF:-main}"
[[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$ref" != *..* ]] ||
  fail 'Set AUTOMATION_REF to a Git ref or commit SHA.'
raw_url="https://raw.githubusercontent.com/daisyorscry/automation/$ref"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

fetch() {
  local path="$1"
  mkdir -p -- "$work_dir/$(dirname -- "$path")"
  curl -fsSL --retry 3 "$raw_url/$path" -o "$work_dir/$path"
}

fetch lib/ipv4.sh
source "$work_dir/lib/ipv4.sh"

if [[ "$1" != gateway-istio ]]; then
  start="$(ipv4_number "${LAN_POOL_START:-}")" || fail 'Set LAN_POOL_START to an IPv4 address.'
  end="$(ipv4_number "${LAN_POOL_END:-}")" || fail 'Set LAN_POOL_END to an IPv4 address.'
  (( start <= end )) || fail 'LAN_POOL_END must be at or after LAN_POOL_START.'
fi

if [[ "$1" != init-istio ]]; then
  if [[ "$template" == cilium-gateway-api ]]; then
    GATEWAY_IP="${GATEWAY_IP:-$LAN_POOL_START}"
    gateway="$(ipv4_number "$GATEWAY_IP")" || fail 'Set GATEWAY_IP to an IPv4 address.'
    (( start <= gateway && gateway <= end )) || fail 'GATEWAY_IP must be inside the LAN pool.'
  elif [[ -n "${GATEWAY_IP:-}" ]]; then
    gateway="$(ipv4_number "$GATEWAY_IP")" || fail 'Set GATEWAY_IP to an IPv4 address.'
    if [[ "$1" == init-istio-gateway ]]; then
      (( start <= gateway && gateway <= end )) || fail 'GATEWAY_IP must be inside the LAN pool.'
    fi
  fi
  [[ "${APP_HOSTNAME:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && "$APP_HOSTNAME" != *.test ]] ||
    fail 'Set APP_HOSTNAME to the application hostname in your Cloudflare zone.'
  if [[ -n "${APP_SERVICE:-}" ]]; then
    [[ "$APP_SERVICE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#APP_SERVICE} -le 63 ]] ||
      fail 'Set APP_SERVICE to the backend Service name in the default namespace.'
    APP_SERVICE_PORT="${APP_SERVICE_PORT:-80}"
    [[ "$APP_SERVICE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( APP_SERVICE_PORT <= 65535 )) ||
      fail 'APP_SERVICE_PORT must be between 1 and 65535.'
  fi
  [[ -n "${ACME_EMAIL:-}" && -n "${CLOUDFLARE_API_TOKEN:-}" ]] ||
    fail 'Set ACME_EMAIL and CLOUDFLARE_API_TOKEN for HTTPS.'
fi

fetch "$installer"
fetch lib/cloudflare-dns01.sh
manifest_dir="manifests/$template"
for file in namespace.yaml gateway.yaml httproute.yaml; do
  fetch "$manifest_dir/$file"
done

if [[ "$template" == cilium-gateway-api ]]; then
  fetch "$manifest_dir/cilium-values.yaml"
  fetch "$manifest_dir/lan.yaml"
  sed -i -e "s/^    - start: .*/    - start: \"$LAN_POOL_START\"/" \
    -e "s/^      stop: .*/      stop: \"$LAN_POOL_END\"/" "$work_dir/$manifest_dir/lan.yaml"
elif [[ "$1" == init-istio* ]]; then
  fetch "$manifest_dir/metallb.yaml"
  sed -i "s/^  - 192\.168\.10\.10-192\.168\.10\.20$/  - $LAN_POOL_START-$LAN_POOL_END/" \
    "$work_dir/$manifest_dir/metallb.yaml"
fi

if [[ "$1" != init-istio ]]; then
  gateway_manifest="$work_dir/$manifest_dir/gateway.yaml"
  sed -i -E "s/^([[:space:]]*hostname:).*/\1 \"$APP_HOSTNAME\"/" "$gateway_manifest"
  if [[ "$template" == cilium-gateway-api ]]; then
    sed -i -E "s/^([[:space:]]*value:) .*/\1 \"$GATEWAY_IP\"/" "$gateway_manifest"
  elif [[ -n "${GATEWAY_IP:-}" ]]; then
    sed -i "/metallb\.io\/address-pool:/a\      metallb.io/loadBalancerIPs: \"$GATEWAY_IP\"" "$gateway_manifest"
  fi
  route_manifest="$work_dir/$manifest_dir/httproute.yaml"
  if [[ -n "${APP_SERVICE:-}" ]]; then
    sed -i -E -e "s/^([[:space:]]*- )app\.example\.test$/\1$APP_HOSTNAME/" \
      -e "s/^([[:space:]]*- name: )app$/\1$APP_SERVICE/" \
      -e "s/^([[:space:]]*port: )80$/\1$APP_SERVICE_PORT/" "$route_manifest"
  else
    # Keep the first document, which redirects HTTP to HTTPS.
    sed -i '/^---$/,$d' "$route_manifest"
  fi
  export GATEWAY_CERT_HOSTNAME="$APP_HOSTNAME"
fi

case "$1" in
  init-istio|init-istio-gateway)
    fetch init-k8s.sh
    bash "$work_dir/init-k8s.sh" --with-istio
    ;;
  init-cilium-gateway)
    fetch init-k8s.sh
    bash "$work_dir/init-k8s.sh" --with-cilium-gateway
    ;;
  gateway-istio) bash "$work_dir/$installer" --gateway-only ;;
  gateway-cilium) bash "$work_dir/$installer" ;;
esac
