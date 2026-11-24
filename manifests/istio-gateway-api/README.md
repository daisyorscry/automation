# Istio ingress with Kubernetes Gateway API

This template uses Istio to provision the gateway Deployment and Service.
MetalLB allocates and announces the Service IP on the LAN.

Use a ready cluster with a working CNI and a schedulable node. If Cilium is the
CNI, assign this IP pool exclusively to MetalLB. This example uses Istio
1.31.4 with Gateway API v1.6.0, a pairing compatible with Kubernetes 1.32.
[Istio version compatibility](https://istio.io/latest/docs/releases/supported-releases/)

## Configure

- Set the LAN pool in `metallb.yaml` and the gateway IP in
  `gateway.yaml`. Keep the IP inside the pool and reserve the pool outside DHCP.
  Use a free IP if installing alongside another gateway.
- Replace the example domain in `gateway.yaml` and the hostname in
  `httproute.yaml`. Point DNS or the upstream proxy at the gateway IP.
- Set the backend name and Service port in `httproute.yaml`. The app route
  and its backend Service use the `default` namespace. To move both, change
  the route namespace and the HTTPS listener's namespace selector together.
- Have a certificate covering the hostname and its matching private key
  ready for the `ingress-tls` Secret.

## Install on a fresh cluster

Run from the repository root.

```bash
kubectl config current-context

kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl -n metallb-system rollout status deployment/controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s
kubectl apply -f manifests/istio-gateway-api/metallb.yaml

helm upgrade --install istio-base base --repo https://istio-release.storage.googleapis.com/charts \
  --namespace istio-system --create-namespace --version 1.31.4 --wait
helm upgrade --install istiod istiod --repo https://istio-release.storage.googleapis.com/charts \
  --namespace istio-system --version 1.31.4 --wait
kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/istio

kubectl apply -f manifests/istio-gateway-api/namespace.yaml
kubectl -n istio-ingress create secret tls ingress-tls --cert=fullchain.pem --key=privkey.pem
kubectl apply -f manifests/istio-gateway-api/gateway.yaml
kubectl apply -f manifests/istio-gateway-api/httproute.yaml
kubectl -n istio-ingress wait --for=condition=Programmed --timeout=300s gateway/public-gateway
kubectl -n istio-ingress get service public-gateway-istio
kubectl -n default describe httproute app-route
```

Check that the Service has the expected external IP and the app route reports
`Accepted=True` and `ResolvedRefs=True` for its HTTPS parent.
