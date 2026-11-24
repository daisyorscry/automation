#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run this installer with sudo.'
(( $# == 1 )) || fail 'Choose init-istio, gateway-istio, or gateway-cilium.'

case "$1" in
  init-istio) installer=install-istio-gateway.sh; template=istio-gateway-api ;;
  gateway-istio) installer=install-istio-gateway.sh; template=istio-gateway-api ;;
  gateway-cilium) installer=install-cilium-gateway.sh; template=cilium-gateway-api ;;
  *) fail "Unknown installer: $1" ;;
esac

ipv4_number() {
  local address="$1" octet number=0
  local -a octets
  [[ "$address" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || return 1
    number=$((number * 256 + octet))
  done
  printf '%s\n' "$number"
}

start="$(ipv4_number "${LAN_POOL_START:-}")" || fail 'Set LAN_POOL_START to an IPv4 address.'
end="$(ipv4_number "${LAN_POOL_END:-}")" || fail 'Set LAN_POOL_END to an IPv4 address.'
(( start <= end )) || fail 'LAN_POOL_END must be at or after LAN_POOL_START.'

if [[ "$1" != init-istio ]]; then
  gateway="$(ipv4_number "${GATEWAY_IP:-}")" || fail 'Set GATEWAY_IP to an IPv4 address.'
  (( start <= gateway && gateway <= end )) || fail 'GATEWAY_IP must be inside the LAN pool.'
  [[ "${APP_HOSTNAME:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && "$APP_HOSTNAME" != *.test ]] ||
    fail 'Set APP_HOSTNAME to the application hostname in your Cloudflare zone.'
  [[ "${APP_SERVICE:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#APP_SERVICE} -le 63 ]] ||
    fail 'Set APP_SERVICE to the backend Service name in the default namespace.'
  APP_SERVICE_PORT="${APP_SERVICE_PORT:-80}"
  [[ "$APP_SERVICE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( APP_SERVICE_PORT <= 65535 )) ||
    fail 'APP_SERVICE_PORT must be between 1 and 65535.'
  [[ -n "${ACME_EMAIL:-}" && -n "${CLOUDFLARE_API_TOKEN:-}" ]] ||
    fail 'Set ACME_EMAIL and CLOUDFLARE_API_TOKEN for HTTPS.'
fi

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
else
  fetch "$manifest_dir/metallb.yaml"
  sed -i "s/^  - 192\.168\.10\.10-192\.168\.10\.20$/  - $LAN_POOL_START-$LAN_POOL_END/" \
    "$work_dir/$manifest_dir/metallb.yaml"
fi

if [[ "$1" == init-istio ]]; then
  fetch init-k8s.sh
  bash "$work_dir/init-k8s.sh" --with-istio
else
  sed -i -E -e "s/^([[:space:]]*hostname:).*/\1 \"$APP_HOSTNAME\"/" \
    -e "s/^([[:space:]]*metallb\.io\/loadBalancerIPs:|[[:space:]]*value:) .*/\1 \"$GATEWAY_IP\"/" \
    "$work_dir/$manifest_dir/gateway.yaml"
  sed -i -E -e "s/^([[:space:]]*- )app\.example\.test$/\1$APP_HOSTNAME/" \
    -e "s/^([[:space:]]*- name: )app$/\1$APP_SERVICE/" \
    -e "s/^([[:space:]]*port: )80$/\1$APP_SERVICE_PORT/" "$work_dir/$manifest_dir/httproute.yaml"
  bash "$work_dir/$installer"
fi
