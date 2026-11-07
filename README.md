# Automation

Script setup Kubernetes control plane menggunakan kubeadm, CRI-O, dan Cilium.

## Install dari GitHub

Jalankan pada node Linux berbasis Debian/Ubuntu yang menggunakan `apt` dan `systemd`, dengan `curl` serta `iproute2` tersedia. Ganti IP berikut dengan IPv4 milik node control plane:

```bash
curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/init-k8s.sh -o init-k8s.sh
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh
```

Atau clone repository:

```bash
git clone https://github.com/daisyorscry/automation.git
cd automation
sudo env CONTROL_PLANE_IP=192.168.10.232 bash init-k8s.sh
```

Script menonaktifkan swap, mengatur kernel dan sysctl, memasang komponen cluster, membuat kubeconfig untuk user pemanggil, dan mencetak perintah join worker. Instalasi dihentikan jika `/etc/kubernetes/admin.conf` sudah ada.

## Konfigurasi

Variabel dapat diatur melalui `sudo env`:

| Variabel | Default | Kegunaan |
| --- | --- | --- |
| `CONTROL_PLANE_IP` | `192.168.10.232` | IPv4 yang terpasang pada node control plane |
| `KUBERNETES_VERSION` | `v1.32` | Versi minor repository Kubernetes |
| `CRIO_VERSION` | `v1.32` | Versi minor repository CRI-O |
| `CILIUM_VERSION` | `1.19.10` | Versi chart Cilium |
| `POD_CIDR` | `10.244.0.0/16` | CIDR pool pod Cilium; gunakan rentang yang tidak bertabrakan dengan jaringan node |

Script ditujukan untuk control plane baru. Kesesuaian versi paket, kernel, dan distribusi perlu dipastikan pada node tujuan.
