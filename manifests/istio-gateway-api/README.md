# Istio ingress with Kubernetes Gateway API

This template uses Istio to provision the gateway Deployment and Service.
MetalLB allocates and announces the Service IP on the LAN.

Use a ready cluster with a working CNI and a schedulable node. If Cilium is the
CNI, assign this IP pool exclusively to MetalLB. This example uses Istio
1.31.4 with Gateway API v1.6.0, a pairing compatible with Kubernetes 1.32.
[Istio version compatibility](https://istio.io/latest/docs/releases/supported-releases/)

## Configure

- Set the LAN pool in `metallb.yaml` and the gateway IP in
  `gateway.yaml`. Keep the IP inside the pool and reserve the pool outside DHCP.
  Use a free IP if installing alongside another gateway.
- Replace the example domain in `gateway.yaml` and the hostname in
  `httproute.yaml`. Point DNS or the upstream proxy at the gateway IP.
- Set the backend name and Service port in `httproute.yaml`. The app route
  and its backend Service use the `default` namespace. To move both, change
  the route namespace and the HTTPS listener's namespace selector together.
- Save a Cloudflare API token with `Zone:DNS:Edit` and `Zone:Zone:Read`
  permissions for the target zone in a protected file on the control plane.

## Install

Run from the repository root after initializing the control plane.

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN_FILE=/path/to/cloudflare-token \
  bash install-istio-gateway.sh
```

The installer uses cert-manager and Cloudflare DNS-01 to issue a Let's Encrypt
certificate for the hostname in `httproute.yaml`. It waits for the certificate
before applying the HTTPS Gateway. Run without the two variables to install
Istio and MetalLB ahead of the HTTPS Gateway.

Check the external IP and route from the control plane.

```bash
kubectl -n istio-ingress get gateway,svc
kubectl -n default describe httproute app-route
```

[Cloudflare DNS-01 token setup](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
