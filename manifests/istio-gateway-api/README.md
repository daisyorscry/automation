# Istio ambient mesh and Gateway API

This template uses Istio to provision the gateway Deployment and Service.
MetalLB allocates and announces the Service IP on the LAN.

Use a ready cluster with a working CNI and a schedulable node. If Cilium is the
CNI, assign this IP pool exclusively to MetalLB. This example uses Istio
1.31.4 with Gateway API v1.6.0, a pairing compatible with Kubernetes 1.32.
[Istio version compatibility](https://istio.io/latest/docs/releases/supported-releases/)

For a complete install from GitHub, see the [setup commands](../../README.md). The steps below are for a local checkout.

## Configure

- Set the LAN pool in `metallb.yaml` during bootstrap and reserve the range
  outside DHCP. MetalLB assigns the Gateway an IP from that pool.
- Replace the example domain in `gateway.yaml` and the hostname in
  `httproute.yaml`. Point DNS or the upstream proxy at the gateway IP.
- Set the backend name and Service port in `httproute.yaml`. The app route
  and its backend Service use the `default` namespace. To move both, change
  the route namespace and the HTTPS listener's namespace selector together.
- Create a Cloudflare API token with `Zone:DNS:Edit` and `Zone:Zone:Read`
  permissions for the target zone.

## Install

Use the [single setup command](../../README.md#install-the-cluster-mesh-and-gateway).
It installs the cluster, Istio ambient components, MetalLB, STRICT mTLS, a
namespace waypoint, and the HTTPS Gateway. Do not run a second Gateway installer.

For a local checkout, after configuring the manifests above:

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash init-k8s.sh --with-istio
```

Add `ALLOW_CONTROL_PLANE_WORKLOADS=true` for a single-node cluster and set
`CONTROL_PLANE_IP` to the node address. Use `MESH_NAMESPACES='default backend'`
to select application namespaces (default: `default`). Other namespaces are not
enrolled. `ENABLE_MESH_WAYPOINT=false` skips L7 waypoints for a fresh install;
it does not remove existing waypoints or labels.

Istio CNI and ztunnel provide ambient mTLS; namespace-scoped PeerAuthentication
requires STRICT mTLS. A waypoint handles service-level L7 traffic. The installer
configures Cilium CNI chaining and host-only socket load balancing while keeping
its installed version. Namespaces with sidecar injection or existing sidecars
must be migrated first. Traffic authorization rules depend on your application
and are not generated automatically.

The installer uses cert-manager and Cloudflare DNS-01 to issue a Let's Encrypt
certificate. Run `bash install-istio-gateway.sh` without TLS variables to install
the mesh and MetalLB on an existing cluster before adding the HTTPS Gateway.
The `--gateway-only` option is retained for updating the Gateway on an already
configured cluster; it does not install or update the mesh.

Check the external IP and route from the control plane.

```bash
kubectl -n istio-ingress get gateway,svc
kubectl -n default describe httproute app-route
```

[Cloudflare DNS-01 token setup](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
