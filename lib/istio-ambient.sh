#!/usr/bin/env bash

validate_ambient_settings() {
  local namespace
  read -r -a mesh_namespaces <<< "${MESH_NAMESPACES:-default}"
  (( ${#mesh_namespaces[@]} > 0 )) || fail 'Set MESH_NAMESPACES to space-separated application namespaces.'
  for namespace in "${mesh_namespaces[@]}"; do
    [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#namespace} -le 63 ]] ||
      fail "Invalid mesh namespace: $namespace"
    case "$namespace" in
      kube-*|istio-system|istio-gateway|cilium-gateway|metallb-system|cert-manager)
        fail "Choose application namespaces for the mesh, not $namespace." ;;
    esac
  done
  [[ "${ENABLE_MESH_WAYPOINT:-true}" =~ ^(true|false)$ ]] ||
    fail 'ENABLE_MESH_WAYPOINT must be true or false.'
}

preflight_ambient_namespaces() {
  local namespace injection revision sidecars existing
  for namespace in "${mesh_namespaces[@]}"; do
    existing="$(kubectl get namespace "$namespace" --ignore-not-found -o name)"
    [[ -n "$existing" ]] || continue
    injection="$(kubectl get namespace "$namespace" -o 'jsonpath={.metadata.labels.istio-injection}')"
    revision="$(kubectl get namespace "$namespace" -o 'jsonpath={.metadata.labels.istio\.io/rev}')"
    [[ "$injection" != enabled && -z "$revision" ]] ||
      fail "Namespace $namespace has sidecar injection labels. Migrate it to ambient before retrying."
    sidecars="$(kubectl -n "$namespace" get pods \
        -o 'jsonpath={range .items[*]}{range .spec.containers[*]}{.name}{"\n"}{end}{range .spec.initContainers[*]}{.name}{"\n"}{end}{end}')"
    [[ ! "$sidecars" =~ (^|$'\n')istio-proxy($|$'\n') ]] ||
      fail "Namespace $namespace contains sidecar pods. Migrate them before enabling ambient."
  done
}

configure_ambient_cilium() {
  local chart_version
  # Cilium is optional for an existing cluster with another primary CNI.
  if [[ -n "$(kubectl -n kube-system get daemonset cilium --ignore-not-found -o name)" ]]; then
    chart_version="$(helm get metadata cilium --namespace kube-system -o yaml | sed -n 's/^version: //p')"
    [[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+-]+)?$ ]] ||
      fail 'Unable to determine the installed Cilium chart version.'
    log 'Configure Cilium for Istio ambient (preserve the installed version and release values)'
    helm upgrade cilium cilium --repo https://helm.cilium.io \
      --namespace kube-system --version "$chart_version" --reuse-values \
      -f "$MANIFEST_DIR/cilium-values.yaml" --wait --timeout 10m
    kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
    log 'Verify Cilium configuration before installing Istio CNI'
    local settings
    settings="$(kubectl -n kube-system get configmap cilium-config \
      -o 'jsonpath={.data.cni-exclusive}{" "}{.data.bpf-lb-sock-hostns-only}{" "}{.data.enable-bpf-masquerade}')"
    [[ "$settings" == 'false true false' ]] ||
      fail "Cilium is not configured for Istio: expected exclusive=false, host-only socket LB=true, BPF masquerade=false; got $settings."
  fi
}

install_ambient_components() {
  log "Install Istio $ISTIO_VERSION ambient mesh"
  local chart
  for chart in base istiod cni ztunnel; do
    log "Install Istio $ISTIO_VERSION component: $chart"
    case "$chart" in
      base)
        helm upgrade --install istio-base base --repo "$ISTIO_REPO" \
          --namespace istio-system --create-namespace --version "$ISTIO_VERSION" \
          --set defaultRevision=default --wait --timeout 5m ;;
      istiod)
        helm upgrade --install istiod istiod --repo "$ISTIO_REPO" \
          --namespace istio-system --version "$ISTIO_VERSION" --set profile=ambient \
          --set-string pilot.env.ENABLE_INGRESS_WAYPOINT_ROUTING=true --wait --timeout 5m ;;
      cni)
        helm upgrade --install istio-cni cni --repo "$ISTIO_REPO" \
          --namespace istio-system --version "$ISTIO_VERSION" \
          --set profile=ambient --wait --timeout 5m ;;
      ztunnel)
        helm upgrade --install ztunnel ztunnel --repo "$ISTIO_REPO" \
          --namespace istio-system --version "$ISTIO_VERSION" --wait --timeout 5m ;;
    esac
  done
  kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout=300s
  kubectl -n istio-system rollout status daemonset/ztunnel --timeout=300s
}

enroll_ambient_namespaces() {
  local namespace
  for namespace in "${mesh_namespaces[@]}"; do
    log "Enable ambient mesh and STRICT mTLS in $namespace"
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$namespace" istio.io/dataplane-mode=ambient --overwrite
    if [[ "${ENABLE_MESH_WAYPOINT:-true}" == true ]]; then
      kubectl -n "$namespace" apply -f "$MANIFEST_DIR/waypoint.yaml"
      kubectl -n "$namespace" wait --for=condition=Programmed --timeout=300s \
        gateways.gateway.networking.k8s.io/waypoint
      kubectl -n "$namespace" rollout status deployment/waypoint --timeout=300s
      kubectl label namespace "$namespace" istio.io/use-waypoint=waypoint \
        istio.io/ingress-use-waypoint=true --overwrite
    fi
    kubectl -n "$namespace" apply -f "$MANIFEST_DIR/peer-authentication.yaml"
  done
}
