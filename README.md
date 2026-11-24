<img src="https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg" alt="Kubernetes logo" width="96">

# Kubernetes Cluster Setup with kubeadm, Cilium, and Istio

Bootstrap a Kubernetes control plane on Debian or Ubuntu with kubeadm, CRI-O, and Cilium. Choose Cilium Gateway API or Istio Gateway API with MetalLB for HTTPS ingress.

Run the commands directly from GitHub. Replace `192.168.10.232` below with your control-plane node's IPv4 address.

## 1. Initialize the Kubernetes control plane

### Cilium

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 bash -c \
  'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/init-k8s.sh) && bash -c "$script"'
```

### Istio and MetalLB

Set the LAN IP range to addresses reserved outside DHCP.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-istio'
```

Both modes use Cilium for pod networking. For a single-node Istio cluster, add `ALLOW_CONTROL_PLANE_WORKLOADS=true` after `sudo env`. If the installer is waiting for a worker, go to [step 3](#3-join-a-kubernetes-worker-node).

## 2. Install an HTTPS Gateway

Run on the control plane. Use an IP inside the LAN pool and the backend Service name and port in the `default` namespace. Use a Cloudflare API token with DNS edit and zone read permissions for your domain.

### Cilium Gateway API

```bash
sudo env ACME_EMAIL=admin@example.com \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 GATEWAY_IP=192.168.10.10 \
  APP_HOSTNAME=app.example.com APP_SERVICE=app APP_SERVICE_PORT=80 \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- gateway-cilium'
```

### Istio Gateway API with MetalLB

Choose a free `GATEWAY_IP` from the MetalLB pool created during Istio bootstrap.

```bash
sudo env ACME_EMAIL=admin@example.com \
  GATEWAY_IP=192.168.10.10 \
  APP_HOSTNAME=app.example.com APP_SERVICE=app APP_SERVICE_PORT=80 \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- gateway-istio'
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
