# Kubernetes with Cilium or Istio Gateway

Kubernetes on Debian/Ubuntu with kubeadm, CRI-O, and Cilium networking.
Choose **one** option below; each installs the cluster and HTTPS Gateway.

Before running:

- Replace the control-plane IP, hostname, email, and Cloudflare token.
- Reserve a free LAN pool outside DHCP. The token needs DNS edit and zone read permissions.
- Commands below temporarily allow workloads on the master so setup finishes before workers join.
- Existing cluster: choose `repair`. `force` deletes cluster state; workers must rejoin.

## Cilium Gateway — without Istio

Cilium handles networking, LAN load balancing, and HTTP/HTTPS Gateway routing.
This option does not configure service mesh or workload mTLS.

```bash
sudo env ALLOW_CONTROL_PLANE_WORKLOADS=true CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 USE_ALL_POOL_IPS=false \
  APP_HOSTNAME=app.example.com \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-cilium-gateway'
```

## Install the cluster, mesh, and Gateway

Cilium networking + MetalLB LAN IP + Istio Gateway, ambient mesh, STRICT mTLS,
and L7 waypoints.
The installer configures Cilium for Istio from the first start and waits for
networking and mesh readiness before continuing to the HTTPS Gateway.

```bash
sudo env ALLOW_CONTROL_PLANE_WORKLOADS=true CONTROL_PLANE_IP=192.168.10.232 \
  LAN_POOL_START=192.168.10.10 LAN_POOL_END=192.168.10.20 USE_ALL_POOL_IPS=false \
  APP_HOSTNAME=app.example.com \
  ACME_EMAIL=admin@example.com CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/run-from-github.sh) && bash -c "$script" -- init-istio-gateway'
```

- Mesh defaults to `default`. Set `MESH_NAMESPACES='default backend'` to select namespaces.
- Existing sidecars must be migrated; pods with mesh opt-out or host networking are not covered automatically.
- STRICT rejects plaintext. Use `AuthorizationPolicy` to restrict access between mesh identities.
- Optional: `ENABLE_MESH_WAYPOINT=false` skips creating L7 waypoints.

For either option, apps can be deployed later. Pass `APP_SERVICE` and
`APP_SERVICE_PORT` (default `80`) to route to an existing Service in `default`.
Set `GATEWAY_IP` to select an IP inside the pool; Cilium defaults to the first IP.
`USE_ALL_POOL_IPS=false` (default): one Gateway. Set `true` for one Gateway per
pool IP, sharing the hostname, TLS, and routes. DNS is configured separately.

For a wildcard Gateway and certificate, use `APP_HOSTNAME='*.runvel.dev'` in
either command. Point wildcard DNS at the Gateway IP. This covers subdomains
such as `app.runvel.dev`, not `runvel.dev` itself. Create an HTTPRoute per app;
setting `APP_SERVICE` during setup routes all matching hostnames to that Service.

## Resume an interrupted install

- Re-run the same installation command with the node's actual `CONTROL_PLANE_IP`.
- Keep `ALLOW_CONTROL_PLANE_WORKLOADS=true` while the master is the only node.
- Choose **`repair`** to preserve the cluster and retry Gateway/mesh setup.
- Early `NotReady` warnings can clear while Cilium starts. Check `kubectl get nodes`
  and `kubectl -n kube-system get pods`; do not choose `force` just to retry.
- If it fails again, capture `ERROR: Failed at line ...` and the preceding error.

## Join workers

On each **worker**, install dependencies and reset old Kubernetes state if present
(type `RESET` to confirm deletion), then reboot.

```bash
sudo bash -c 'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/reset-to-worker.sh) && bash -c "$script"'
sudo reboot
```

On the **control plane**, generate the join command:

```bash
sudo kubeadm token create --print-join-command
```

Run the printed command on each prepared worker with `sudo` and append
`--cri-socket unix:///var/run/crio/crio.sock`. Confirm with `kubectl get nodes`.

## Isolate the master after workers join

Run on the control plane. Replace both node names; ensure workers have enough capacity.

```bash
MASTER_NODE=runvel-workspace-master
WORKER_NODE=your-worker-name
kubectl wait --for=condition=Ready "node/$WORKER_NODE" --timeout=300s
kubectl taint node "$MASTER_NODE" node-role.kubernetes.io/control-plane:NoSchedule --overwrite
```

This blocks new ordinary workloads on the master. To move existing workloads too:

```bash
kubectl drain "$MASTER_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=10m
# Run only after drain succeeds; the NoSchedule taint stays in place.
kubectl uncordon "$MASTER_NODE"
kubectl get pods -A -o wide
```

Drain restarts workloads and discards their `emptyDir` data. Local persistent
volumes need separate migration. If blocked by a disruption budget, resolve it
before continuing. Control-plane static pods and system DaemonSets remain.

For MetalLB, also stop advertising Gateway IPs from the master:

```bash
kubectl label node "$MASTER_NODE" node.kubernetes.io/exclude-from-external-load-balancers=true --overwrite
```

## Verify

On the control plane, after nodes are ready. Use `cilium-gateway` for Cilium
or `istio-gateway` for Istio:

```bash
GATEWAY_NAMESPACE=istio-gateway bash -c \
  'script=$(curl -fsSL https://raw.githubusercontent.com/daisyorscry/automation/main/verify-cluster.sh) && bash -c "$script"'
```

This tests HTTPS using a temporary app, then removes it. Set `APP_HOSTNAME`
to a concrete name such as `app.runvel.dev` when using a wildcard certificate.

For Istio, also check:

```bash
kubectl -n istio-system get pods
kubectl get namespaces -L istio.io/dataplane-mode,istio.io/use-waypoint
kubectl -n default get peerauthentication default -o yaml
```

Confirm mesh-to-mesh traffic works and plaintext clients are rejected;
component readiness alone does not verify mTLS traffic.
