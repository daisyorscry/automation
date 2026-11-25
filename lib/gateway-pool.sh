#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ipv4.sh"

validate_gateway_pool_settings() {
  [[ "${USE_ALL_POOL_IPS:-false}" =~ ^(true|false)$ ]] ||
    fail 'USE_ALL_POOL_IPS must be true or false.'
  if [[ "${USE_ALL_POOL_IPS:-false}" == true ]]; then
    [[ -z "${GATEWAY_IP:-}" ]] || fail 'Choose USE_ALL_POOL_IPS=true or GATEWAY_IP, not both.'
    gateway_pool_start="$(ipv4_number "${LAN_POOL_START:-}")" || fail 'Set LAN_POOL_START for USE_ALL_POOL_IPS=true.'
    gateway_pool_end="$(ipv4_number "${LAN_POOL_END:-}")" || fail 'Set LAN_POOL_END for USE_ALL_POOL_IPS=true.'
    (( gateway_pool_start <= gateway_pool_end )) || fail 'LAN_POOL_END must be at or after LAN_POOL_START.'
  fi
}

plan_public_gateways() {
  local address ip
  gateway_names=(public-gateway)
  gateway_ips=("")
  [[ "${USE_ALL_POOL_IPS:-false}" == true ]] || return 0
  gateway_names=()
  gateway_ips=()
  for ((address=gateway_pool_start; address<=gateway_pool_end; address++)); do
    ip="$((address >> 24 & 255)).$((address >> 16 & 255)).$((address >> 8 & 255)).$((address & 255))"
    if (( address == gateway_pool_start )); then
      gateway_names+=(public-gateway)
    else
      gateway_names+=("public-gateway-${ip//./-}")
    fi
    gateway_ips+=("$ip")
  done
}

validate_public_gateway_ips() {
  local controller="$1" services namespace service addresses ip number name
  local -a allowed_services
  allowed_services=()
  for name in "${gateway_names[@]}"; do
    if [[ "$controller" == istio ]]; then service="$name-istio";
    else service="cilium-gateway-$name"; fi
    allowed_services+=("$PUBLIC_GATEWAY_NAMESPACE/$service")
  done
  services="$(kubectl get services -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .status.loadBalancer.ingress[*]}{.ip}{" "}{end}{"\n"}{end}')"
  while read -r namespace service addresses; do
    for ip in $addresses; do
      if number="$(ipv4_number "$ip")" && (( gateway_pool_start <= number && number <= gateway_pool_end )); then
        case " ${allowed_services[*]} " in
          *" $namespace/$service "*) ;;
          *) fail "Pool IP $ip is already assigned to $namespace/$service. Choose a free range before enabling USE_ALL_POOL_IPS." ;;
        esac
      fi
    done
  done <<< "$services"
}

prepare_public_gateway_manifests() {
  local controller="$1" index count names
  gateway_manifest="$MANIFEST_DIR/gateway.yaml"
  route_manifest="$MANIFEST_DIR/httproute.yaml"
  if [[ "$controller" == istio ]]; then gateway_pool_manifest="$MANIFEST_DIR/metallb.yaml";
  else gateway_pool_manifest="$MANIFEST_DIR/lan.yaml"; fi
  plan_public_gateways
  [[ "${USE_ALL_POOL_IPS:-false}" == true ]] || return 0
  validate_public_gateway_ips "$controller"
  GATEWAY_WORK_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$GATEWAY_WORK_DIR"' EXIT
  gateway_manifest="$GATEWAY_WORK_DIR/gateway.yaml"
  route_manifest="$GATEWAY_WORK_DIR/httproute.yaml"
  if [[ "$controller" == istio && -r "$MANIFEST_DIR/metallb.yaml" ]]; then
    gateway_pool_manifest="$GATEWAY_WORK_DIR/metallb.yaml"
    sed -E "s/^  - [0-9.]+-[0-9.]+$/  - $LAN_POOL_START-$LAN_POOL_END/" \
      "$MANIFEST_DIR/metallb.yaml" > "$gateway_pool_manifest"
  elif [[ "$controller" == cilium ]]; then
    gateway_pool_manifest="$GATEWAY_WORK_DIR/lan.yaml"
    sed -E -e "s/^    - start: .*/    - start: \"$LAN_POOL_START\"/" \
      -e "s/^      stop: .*/      stop: \"$LAN_POOL_END\"/" \
      "$MANIFEST_DIR/lan.yaml" > "$gateway_pool_manifest"
  fi
  count=${#gateway_names[@]}
  log "Prepare $count public Gateways, one per pool IP"
  for ((index=0; index<count; index++)); do
    (( index == 0 )) || printf '%s\n' '---' >> "$gateway_manifest"
    awk -v name="${gateway_names[index]}" -v ip="${gateway_ips[index]}" -v controller="$controller" '
      /^  name: public-gateway$/ { print "  name: " name; next }
      /metallb.io\/loadBalancerIPs:/ { next }
      /metallb.io\/address-pool:/ {
        print
        if (controller == "istio") print "      metallb.io/loadBalancerIPs: \"" ip "\""
        next
      }
      controller == "cilium" && /^[ ]*value:/ { sub(/value:.*/, "value: \"" ip "\"") }
      { print }
    ' "$MANIFEST_DIR/gateway.yaml" >> "$gateway_manifest"
  done
  names="$(printf '%s ' "${gateway_names[@]}")"
  # HTTPRoute permits at most 32 parents. Larger pools use additional route
  # documents with the same rules, each attached to a different group of parents.
  awk -v names="$names" -v namespace="$PUBLIC_GATEWAY_NAMESPACE" '
    function emit(    section, first, last, batch, i, j, skip, line) {
      if (!lines) return
      section="https"
      for (i=1; i<=lines; i++) if (document[i] ~ /sectionName: http$/) section="http"
      for (first=1; first<=gateways; first+=32) {
        batch=int((first-1)/32)
        last=first+31; if (last>gateways) last=gateways
        if (emitted++) print "---"
        skip=0
        for (i=1; i<=lines; i++) {
          line=document[i]
          if (skip) {
            if (line !~ /^  [A-Za-z]/) continue
            skip=0
          }
          if (line ~ /^  name:/ && batch) line=line "-" (batch+1)
          if (line ~ /^  parentRefs:/) {
            print line
            for (j=first; j<=last; j++) {
              print "    - name: " gateway[j]
              print "      namespace: " namespace
              print "      sectionName: " section
            }
            skip=1
          } else print line
        }
      }
      delete document; lines=0
    }
    BEGIN { gateways=split(names, gateway, " ") }
    /^---$/ { emit(); next }
    { document[++lines]=$0 }
    END { emit() }
  ' "$MANIFEST_DIR/httproute.yaml" > "$route_manifest"
}

wait_for_public_gateways() {
  local controller="$1" index name service actual_ip
  for ((index=0; index<${#gateway_names[@]}; index++)); do
    name="${gateway_names[index]}"
    log "Wait for $name"
    kubectl -n "$PUBLIC_GATEWAY_NAMESPACE" wait --for=condition=Programmed --timeout=300s \
      "gateways.gateway.networking.k8s.io/$name"
    if [[ "$controller" == istio ]]; then
      service="$name-istio"
      kubectl -n "$PUBLIC_GATEWAY_NAMESPACE" rollout status "deployment/$service" --timeout=300s
    else
      service="cilium-gateway-$name"
    fi
    kubectl -n "$PUBLIC_GATEWAY_NAMESPACE" wait --for='jsonpath={.status.loadBalancer.ingress[0].ip}' \
      --timeout=120s "service/$service"
    actual_ip="$(kubectl -n "$PUBLIC_GATEWAY_NAMESPACE" get "service/$service" -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')"
    [[ -z "${gateway_ips[index]}" || "$actual_ip" == "${gateway_ips[index]}" ]] ||
      fail "$name received $actual_ip instead of requested ${gateway_ips[index]}."
  done
}
