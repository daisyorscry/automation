<div align="center">

# Automation

**From a fresh node to a Kubernetes cluster.**

Kubeadm · CRI-O · Cilium

[Create a control plane](#create-a-control-plane) · [Istio and MetalLB](#create-a-control-plane-with-istio-and-metallb) · [Prepare a worker](#prepare-a-worker) · [Configuration](#configuration)

</div>

---

Requires a Debian/Ubuntu node with **systemd**, **sudo**, **curl**, and **iproute2**. Run these commands on the target node.

## Create a control plane

Download the script and replace `192.168.10.232` with your node's IPv4 address:

```bash
curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/init-k8s.sh -o init-k8s.sh
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh
```

Sets up Kubernetes with CRI-O and Cilium, configures `kubectl` for your user, and prints a worker join command. Existing Kubernetes files, etcd data, or occupied Kubernetes ports trigger a menu:

- `repair`: preserve cluster data, restart services, skip `kubeadm init`, and reconcile the existing Cilium Helm release with its saved values. Requires the original control-plane configuration and PKI; does not recreate deleted files or migrate the API IP. Kubernetes packages stay at their installed versions.
- `force`: type `RESET` to delete local cluster state (including local etcd) and create a new cluster. Existing workers must rejoin. Use only when rebuilding this node is intended.
- Enter or any other input: cancel.

If `/etc/kubernetes` was deleted, restore it from backup for repair, or choose `force` to rebuild.

After Cilium installation, the script waits for the local CNI configuration, restarts CRI-O and kubelet to load it, and waits for the API server to recover. The worker join command is printed before readiness checks so workers can join while validation runs. Installation completes only after Cilium, nodes, and CoreDNS are ready. On validation errors, the script prints node taints, CoreDNS scheduling events, and local runtime logs to show the cause.

## Create a control plane with Istio and MetalLB

From a full checkout on the target node, configure the LAN pool in
`manifests/istio-gateway-api/metallb.yaml`. Reserve the range outside DHCP
and keep it separate from other load balancer pools.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh --with-istio
```

This bootstraps kubeadm, CRI-O, and Cilium for pod networking. It then installs
the Kubernetes Gateway API CRDs, Istio, and MetalLB with the configured L2 pool.
For a dedicated control plane, join a worker using the command printed during
bootstrap. On a single-node cluster, pass `ALLOW_CONTROL_PLANE_WORKLOADS=true`
through `sudo env` to allow regular workloads and MetalLB IP advertisements
on the control-plane node.

To provision the HTTPS Gateway in the same run, set `GATEWAY_TLS_CERT` and
`GATEWAY_TLS_KEY` to absolute file paths. First configure the gateway IP,
hostname, and application Service in the
[Istio Gateway API manifests](manifests/istio-gateway-api/README.md).
The application route needs its backend Service to serve traffic.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 ALLOW_CONTROL_PLANE_WORKLOADS=true \
  GATEWAY_TLS_CERT=/path/to/fullchain.pem GATEWAY_TLS_KEY=/path/to/privkey.pem \
  bash init-k8s.sh --with-istio
```

After bootstrap, use `sudo bash install-istio-gateway.sh` to rerun the addon
installation directly. Pass the same TLS variables to install the Gateway
and routes when the certificate becomes available.

## Prepare a worker

> **Destructive:** resets local Kubernetes state, including local etcd on a control plane. Only use on a node you intend to rebuild.

```bash
curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/reset-to-worker.sh -o reset-to-worker.sh
sudo bash reset-to-worker.sh
sudo reboot
```

Type `RESET` when prompted. For unattended use, pass `--yes`.

After reboot, generate a fresh join command **on the target control plane**:

```bash
sudo kubeadm token create --print-join-command
```

Run the printed command **on the worker** with `sudo` and append `--cri-socket unix:///var/run/crio/crio.sock`.

## Configuration

Override defaults with `sudo env NAME=value bash <script>`. Keep the worker's Kubernetes version aligned with the control plane.

| Variable | Default | Applies to |
| --- | --- | --- |
| `KUBERNETES_VERSION` | `v1.32` | Both scripts |
| `CRIO_VERSION` | `v1.32` | Both scripts |
| `CONTROL_PLANE_IP` | `192.168.10.232` | Control plane |
| `CILIUM_VERSION` | `1.19.10` | Control plane |
| `POD_CIDR` | `10.244.0.0/16` | Control plane; must not overlap the node network |

## Gateway templates

- [Istio legacy gateway](manifests/istio-legacy-gateway) uses Istio's own
  `Gateway` and `VirtualService` resources with MetalLB.
- [Istio Gateway API](manifests/istio-gateway-api/README.md) uses Kubernetes
  `Gateway` and `HTTPRoute` resources with Istio and MetalLB.
- [Cilium Gateway API](manifests/cilium-gateway-api/README.md) uses Kubernetes
  `Gateway` and `HTTPRoute` resources with Cilium LB IPAM and L2 Announcements.

### Set up the Istio legacy gateway

Use the legacy gateway manifests on a cluster with a working CNI and a
schedulable node. If the cluster uses Cilium, configure MetalLB as the only
component managing and announcing IPs from this pool.

Before installing, set the LAN range in `metallb.yaml` and the requested
gateway IP in `istio-ingress-values.yaml`. Keep the gateway IP inside the pool
and reserve the pool outside DHCP.

```bash
kubectl config current-context

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl -n metallb-system rollout status deployment/controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s
kubectl apply -f manifests/istio-legacy-gateway/metallb.yaml

helm upgrade --install istio-base base --repo https://istio-release.storage.googleapis.com/charts \
  --namespace istio-system --create-namespace --version 1.30.1 --wait
helm upgrade --install istiod istiod --repo https://istio-release.storage.googleapis.com/charts \
  --namespace istio-system --version 1.30.1 --wait
helm upgrade --install istio-ingressgateway gateway --repo https://istio-release.storage.googleapis.com/charts \
  --namespace istio-ingress --create-namespace --version 1.30.1 --wait \
  -f manifests/istio-legacy-gateway/istio-ingress-values.yaml
```

Replace `*.example.test` in `gateway.yaml` and `app.example.test` in
`virtualservice.yaml` with your domain and hostname. Set the destination to
your application's Kubernetes Service DNS name and port. Point the DNS record
or upstream proxy at the ingress IP.

Create the gateway's TLS Secret using a certificate that covers the hostname
and its matching private key.

```bash
kubectl -n istio-ingress create secret tls ingress-tls --cert=fullchain.pem --key=privkey.pem
kubectl apply -f manifests/istio-legacy-gateway/gateway.yaml
kubectl apply -f manifests/istio-legacy-gateway/virtualservice.yaml
kubectl -n istio-ingress get service istio-ingressgateway
```
