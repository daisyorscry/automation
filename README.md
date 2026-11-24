<img src="https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg" alt="Kubernetes logo" width="96">

# Kubernetes Cluster Setup with kubeadm, Cilium, and Istio

Bootstrap a Kubernetes control plane on Debian or Ubuntu with kubeadm, CRI-O, and Cilium. Choose Cilium Gateway API or Istio Gateway API with MetalLB for HTTPS ingress.

Run the commands directly from GitHub. Replace `192.168.10.232` below with your control-plane node's IPv4 address.

Choose one control-plane setup. Set a free LAN pool outside DHCP, the backend
Service in the `default` namespace, and a Cloudflare token with DNS edit and zone
read permissions. For a single-node cluster, add `ALLOW_CONTROL_PLANE_WORKLOADS=true`
after `sudo env`. If setup is waiting for a worker, go to [Join a worker](#join-a-kubernetes-worker-node).

## 1. Install Cilium and Cilium Gateway

Cilium uses the first IP in the pool by default.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 \
  APP_HOSTNAME=app.example.com APP_SERVICE=app APP_SERVICE_PORT=80 \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-cilium-gateway'
```

## 2. Install Istio, MetalLB, and Istio Gateway

Cilium handles pod networking. MetalLB assigns the Gateway IP from the pool.

```bash
sudo env CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 \
  APP_HOSTNAME=app.example.com APP_SERVICE=app APP_SERVICE_PORT=80 \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-istio-gateway'
```

Point your DNS record or upstream proxy at the gateway IP and deploy the backend Service referenced by the route.

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

[Legacy Istio Gateway and VirtualService manifests](manifests/istio-legacy-gateway)
