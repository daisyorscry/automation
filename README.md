<img src="https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg" alt="Kubernetes logo" width="96">

# Kubernetes Cluster Setup with kubeadm, Cilium, and Istio

Bootstrap a Kubernetes control plane on Debian or Ubuntu with kubeadm, CRI-O, and Cilium. Choose Cilium Gateway API or Istio Gateway API with MetalLB for HTTPS ingress.

Run these commands from a checkout of this repository. Replace `192.168.10.232` with your control-plane node's IPv4 address.

## 1. Initialize the Kubernetes control plane

### Cilium

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh
```

### Istio and MetalLB

Set the LAN IP range in [metallb.yaml](manifests/istio-gateway-api/metallb.yaml), then run:

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh --with-istio
```

Both modes use Cilium for pod networking. For a single-node Istio cluster, add `ALLOW_CONTROL_PLANE_WORKLOADS=true` after `sudo env`. If the installer is waiting for a worker, go to [step 3](#3-join-a-kubernetes-worker-node).

## 2. Install an HTTPS Gateway

Choose the gateway that matches your setup. In its template folder, set the LAN IP and listener hostnames in `gateway.yaml`, then set the application hostname and backend Service in `httproute.yaml`. Use a gateway IP inside the configured pool.

### Cilium Gateway API with Cloudflare DNS-01

Set the LAN range in [lan.yaml](manifests/cilium-gateway-api/lan.yaml) and save a Cloudflare API token on the control plane. [Cloudflare token setup](manifests/cilium-gateway-api/README.md#configure)

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN_FILE=/path/to/cloudflare-token \
  bash install-cilium-gateway.sh
```

### Istio Gateway API with MetalLB

Use the [Istio Gateway API manifests](manifests/istio-gateway-api) and provide a TLS certificate and its private key.

```bash
sudo env GATEWAY_TLS_CERT=/path/to/fullchain.pem \
  GATEWAY_TLS_KEY=/path/to/privkey.pem \
  bash install-istio-gateway.sh
```

Point your DNS record or upstream proxy at the gateway IP and deploy the backend Service referenced by the route.

## 3. Join a Kubernetes worker node

On the **worker**, run the commands below. Type `RESET` when prompted to erase any existing Kubernetes state on that node.

```bash
sudo bash reset-to-worker.sh
sudo reboot
```

On the **control plane**, print a fresh join command:

```bash
sudo kubeadm token create --print-join-command
```

After reboot, run the printed `kubeadm join` command on the **worker** with `sudo` and append `--cri-socket unix:///var/run/crio/crio.sock`. Verify the worker from the control plane with `kubectl get nodes`.

[Legacy Istio Gateway and VirtualService manifests](manifests/istio-legacy-gateway)
