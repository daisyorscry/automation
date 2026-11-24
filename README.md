<img src="https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg" alt="Kubernetes logo" width="96">

# Kubernetes Cluster Setup with kubeadm, Cilium, and Istio

Bootstrap a Kubernetes control plane on Debian or Ubuntu with kubeadm, CRI-O, and Cilium. Choose Cilium Gateway API or Istio Gateway API with MetalLB for HTTPS ingress.

Run the commands directly from GitHub. Replace `192.168.10.232` below with your control-plane node's IPv4 address.

Choose one control-plane setup. Set a free LAN pool outside DHCP, a hostname in
your Cloudflare zone, and a Cloudflare token with DNS edit and zone read permissions. For a single-node cluster, add `ALLOW_CONTROL_PLANE_WORKLOADS=true`
after `sudo env`. If setup is waiting for a worker, go to [Join a worker](#join-a-kubernetes-worker-node).

## 1. Install Cilium and Cilium Gateway

Cilium uses the first IP in the pool by default.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 \
  APP_HOSTNAME=app.example.com \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-cilium-gateway'
```

## 2. Install Istio, MetalLB, and Istio Gateway

Cilium handles pod networking. MetalLB assigns the Gateway IP from the pool.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 \
  APP_HOSTNAME=app.example.com \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-istio-gateway'
```

The Gateway and TLS certificate can be installed before any app. If your Service
already exists in `default`, pass `APP_SERVICE` and optionally
`APP_SERVICE_PORT` (default `80`) to create its route during setup.

## Join a Kubernetes worker node

On the **worker**, run the reset script directly from GitHub. Type `RESET` when prompted to erase any existing Kubernetes state on that node, then reboot.

```bash
sudo bash -c \
  'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/reset-to-worker.sh) && bash -c "$script"'
sudo reboot
```

On the **control plane**, print a fresh join command:

```bash
sudo kubeadm token create --print-join-command
```

After reboot, run the printed `kubeadm join` command on the **worker** with `sudo` and append `--cri-socket unix:///var/run/crio/crio.sock`. Verify the worker from the control plane with `kubectl get nodes`.

## Verify the cluster and HTTPS Gateway

On the control plane, deploy a test app after the worker is `Ready`. Use the
hostname from the install command and set `GATEWAY_NAMESPACE` to
`cilium-ingress` or `istio-ingress`. Run this on the hostname if it has no app route yet.

```bash
APP_HOSTNAME=app.example.com
GATEWAY_NAMESPACE=cilium-ingress

kubectl get nodes
kubectl -n default create deployment gateway-smoke --image=nginx
kubectl -n default expose deployment gateway-smoke --port=80
kubectl -n default rollout status deployment/gateway-smoke --timeout=180s

kubectl apply -f - <<EOF_ROUTE
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gateway-smoke
  namespace: default
spec:
  parentRefs:
    - name: public-gateway
      namespace: $GATEWAY_NAMESPACE
      sectionName: https
  hostnames:
    - "$APP_HOSTNAME"
  rules:
    - backendRefs:
        - name: gateway-smoke
          port: 80
EOF_ROUTE

GATEWAY_IP=$(kubectl -n "$GATEWAY_NAMESPACE" get gateways.gateway.networking.k8s.io public-gateway \
  -o 'jsonpath={.status.addresses[0].value}')
curl --fail --retry 10 --retry-all-errors --retry-delay 2 \
  --resolve "$APP_HOSTNAME:443:$GATEWAY_IP" "https://$APP_HOSTNAME/"
```

A successful request returns the nginx welcome page. Point your DNS record or
upstream proxy at the Gateway IP for regular access.

Remove the test app and route when done.

```bash
kubectl -n default delete httproute/gateway-smoke service/gateway-smoke deployment/gateway-smoke
```

[Legacy Istio Gateway and VirtualService manifests](manifests/istio-legacy-gateway)
