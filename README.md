<img src="https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg" alt="Kubernetes logo" width="96">

# Kubernetes Cluster Setup with kubeadm, Cilium, and Istio

Bootstrap a Kubernetes control plane on Debian or Ubuntu with kubeadm, CRI-O, and Cilium. Choose Cilium Gateway API or Istio Gateway API with MetalLB for HTTPS ingress.

Replace `192.168.10.232` below with your control-plane node's IPv4 address.

## 1. Initialize the Kubernetes control plane

### Cilium

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash -c \
  'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/init-k8s.sh) && bash -c "$script"'
```

### Istio and MetalLB

Clone the repository once for Istio or either HTTPS Gateway installer. These installers use the manifests and helper scripts from the checkout.

```bash
git clone https://github.com/daisyorscry/automation.git
cd automation
```

Set the LAN IP range in [metallb.yaml](manifests/istio-gateway-api/metallb.yaml), then run:

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh --with-istio
```

Both modes use Cilium for pod networking. For a single-node Istio cluster, add `ALLOW_CONTROL_PLANE_WORKLOADS=true` after `sudo env`. If the installer is waiting for a worker, go to [step 3](#3-join-a-kubernetes-worker-node).

## 2. Install an HTTPS Gateway

Run the gateway installer from the [repository checkout](#istio-and-metallb). In its template folder, set the LAN IP and listener hostnames in `gateway.yaml`, then set the application hostname and backend Service in `httproute.yaml`. Use a gateway IP inside the configured pool.

### Cilium Gateway API with Cloudflare DNS-01

Set the LAN range in [lan.yaml](manifests/cilium-gateway-api/lan.yaml) and create a Cloudflare API token for the target zone. [Cloudflare token setup](manifests/cilium-gateway-api/README.md#configure)

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash install-cilium-gateway.sh
```

### Istio Gateway API with MetalLB and Cloudflare DNS-01

Use the [Istio Gateway API manifests](manifests/istio-gateway-api) and a Cloudflare API token for the target DNS zone.

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash install-istio-gateway.sh
```

Point your DNS record or upstream proxy at the gateway IP and deploy the backend Service referenced by the route.

## 3. Join a Kubernetes worker node

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

[Legacy Istio Gateway and VirtualService manifests](manifests/istio-legacy-gateway)
