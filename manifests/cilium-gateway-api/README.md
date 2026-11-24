# Cilium Gateway API ingress

This template uses the Cilium release installed by `init-k8s.sh`. Cilium
creates the gateway LoadBalancer Service and uses Envoy for HTTP routing and
TLS. LB IPAM allocates the address and L2 Announcements advertises it on the LAN.
The pool and L2 policy select Services in the dedicated `cilium-ingress` namespace.

For the raw GitHub command, see [Install an HTTPS Gateway](../../README.md#2-install-an-https-gateway). The steps below are for a local checkout.

## Configure

- Set the LAN range in `lan.yaml` and the requested IP in `gateway.yaml`.
  Reserve the range outside DHCP and keep it separate from any existing
  load balancer pools. The node interface facing the client LAN must be
  managed by Cilium.
- Replace the example domain in `gateway.yaml` and hostname in
  `httproute.yaml`. Set the backend to your application's Service name and
  port in `default`. To move the route and Service together, update the
  HTTPS listener's namespace selector as well.
- Create a Cloudflare API token with `Zone:DNS:Edit` and `Zone:Zone:Read`
  for the target zone. Configure the application DNS record or upstream proxy separately.

## Install

Run from the repository root after `init-k8s.sh`. The installer uses Cilium
1.19.10 and Gateway API v1.4.1.

```bash
sudo env ACME_EMAIL=admin@example.com \
  CLOUDFLARE_API_TOKEN='your-cloudflare-token' \
  bash install-cilium-gateway.sh
```

The installer enables Gateway API and L2 Announcements in the existing
Cilium release and applies the LAN pool. For HTTPS, it uses cert-manager
to issue a Let's Encrypt certificate for the hostname in `httproute.yaml`
via Cloudflare DNS-01. It waits for the `ingress-tls` Secret to be issued
before applying the Gateway. An existing cert-manager installation is reused.
The token and ACME issuer are scoped to `cilium-ingress`.

Run `sudo bash install-cilium-gateway.sh` with no variables to prepare
Cilium Gateway API and the LAN pool before setting up HTTPS.

Check the external IP and the route's `Accepted` and `ResolvedRefs` conditions.
From a client on the LAN, test HTTP redirect and HTTPS after setting DNS.

- [Cilium 1.19.10 Gateway API installation](https://github.com/cilium/cilium/blob/v1.19.10/Documentation/network/servicemesh/gateway-api/installation.rst)
- [Cilium LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [cert-manager Cloudflare DNS-01](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
