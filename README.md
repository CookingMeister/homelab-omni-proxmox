# talos-cluster

GitOps repository for `talos-cluster-1` — a 3-node Talos Linux cluster on Proxmox,
managed by [Sidero Omni](https://omni.fullstackchef.dev).

## Cluster

| Node | IP | Role | Disk |
| --- | --- | --- | --- |
| talos-05t-4cw | 192.168.0.224 | control-plane | 34 GB |
| talos-b3y-x1d | 192.168.0.246 | worker | 64 GB |
| talos-jrf-41p | 192.168.0.77 | worker | 64 GB |

Talos v1.13.5 · Kubernetes v1.36.2 · Cilium 1.20.1 · 4 vCPU / 8 GB RAM per node.

Control planes are untainted (Omni system patch `400-talos-cluster-1-control-planes-untaint`),
so workloads schedule on all three nodes.

## Layout

```
clusters/talos-cluster-1/   Flux entrypoint - Kustomizations pointing at the trees below
infrastructure/controllers/ Cluster-wide controllers (Cilium, metrics-server)
infrastructure/configs/     Cluster-wide config that depends on those controllers
apps/talos-cluster-1/       Workloads (Homepage dashboard)
```

Reconcile order: `infra-controllers` → `infra-configs`, with `apps` depending on
`infra-controllers`.

## Networking

Cilium replaces both Flannel and kube-proxy. That requires Talos to ship neither,
which is done by the Omni config patch `400-talos-cluster-1-cilium-cni-none`:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

Cilium talks to the API server through Talos **KubePrism** on `localhost:7445`
rather than a service VIP, which is what makes kube-proxy replacement work before
any CNI is up.

### LoadBalancer addresses — not yet active

`infrastructure/configs/cilium-l2.yaml` defines a `CiliumLoadBalancerIPPool` and a
`CiliumL2AnnouncementPolicy`, but they are **deliberately not applied**: the IP
range is still a placeholder. To enable:

1. Find a block inside `192.168.0.0/24` that is outside your router's DHCP pool.
   Existing nodes are at `.77`, `.224` and `.246`, so DHCP reaches high into the
   subnet — check the router rather than guessing.
2. Put that range in `cilium-l2.yaml`.
3. Uncomment `- cilium-l2.yaml` in `infrastructure/configs/kustomization.yaml`.
4. Flip Homepage's `service.main.type` to `LoadBalancer` and add the resulting IP
   to `HOMEPAGE_ALLOWED_HOSTS`.

## Accessing things before LoadBalancer IPs exist

```sh
export KUBECONFIG=.kube/talos-cluster-1-kubeconfig.yaml

# Homepage
kubectl -n homepage port-forward svc/homepage 3000:3000
# -> http://localhost:3000

# Hubble UI (Cilium network observability)
kubectl -n kube-system port-forward svc/hubble-ui 8080:80
# -> http://localhost:8080
```

## Notes

- **`metrics-server` runs with `--kubelet-insecure-tls`.** Talos kubelets serve
  certificates metrics-server cannot verify unless kubelet server-cert rotation and
  an approver are enabled cluster-wide. The flag is an accepted trade-off on a
  trusted LAN; see the comment in the HelmRelease.
- **Cilium was installed by hand at bootstrap** and is adopted by the HelmRelease
  because the release name and namespace match. Keep the values in that HelmRelease
  in sync with reality — it is now the source of truth.
- **There is no StorageClass.** Every node has only its OS disk, so nothing is
  provisioning PVCs. Homepage does not need one (its config lives in Git), but
  anything stateful will. `local-path-provisioner` is the usual next step.
- **Single control plane.** The cluster is not HA. Promoting the two workers to
  control planes in Omni would fix that.
