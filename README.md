<div align="center">

# Automation

**From a fresh node to a Kubernetes cluster.**

Kubeadm · CRI-O · Cilium

[Create a control plane](#create-a-control-plane) · [Prepare a worker](#prepare-a-worker) · [Configuration](#configuration)

</div>

---

Requires a Debian/Ubuntu node with **systemd**, **sudo**, **curl**, and **iproute2**. Run these commands on the target node.

## Create a control plane

Download the script and replace `192.168.10.232` with your node's IPv4 address:

```bash
curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/init-k8s.sh -o init-k8s.sh
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh
```

Sets up Kubernetes with CRI-O and Cilium, configures `kubectl` for your user, and prints a worker join command. Use a fresh node; an existing control plane is rejected.

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
