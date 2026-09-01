# talos-cluster

GitOps repository for `talos-cluster-1` — a 3-node Talos Linux cluster running on
Proxmox, managed by [Sidero Omni](https://omni.fullstackchef.dev) and reconciled by
Flux CD.

Cilium provides networking (replacing both Flannel and kube-proxy) and hands out
LAN addresses for `LoadBalancer` services via L2 announcements. A Traefik instance
outside the cluster publishes those services under `home.fullstackchef.dev`.

## Cluster

| Node | IP | Role | Disk |
| --- | --- | --- | --- |
| talos-05t-4cw | 192.168.0.224 | control-plane | 34 GB |
| talos-zdx-y3b | 192.168.0.246 | control-plane | 64 GB |
| talos-3z8-t6d | 192.168.0.77 | control-plane | 64 GB |

Talos v1.13.5 · Kubernetes v1.36.2 · Cilium 1.20.1 · 4 vCPU / 8 GB RAM per node.

All three nodes are control planes running etcd, so the cluster tolerates losing
one (quorum 2 of 3). The `talos-cluster-1-workers` machine set is empty.

They are also untainted (Omni system patch `400-talos-cluster-1-control-planes-untaint`),
so workloads schedule on all three.

> Node names are assigned by Omni and change when a machine is reprovisioned — the
> two promoted nodes were previously `talos-b3y-x1d` and `talos-jrf-41p`. Never pin
> a workload to a node by name; use labels.

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

Cilium replaces Flannel and kube-proxy. That requires Talos to ship neither, which
is done by the Omni config patch `400-talos-cluster-1-cilium-cni-none`:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

Cilium reaches the API server through Talos **KubePrism** on `localhost:7445`
rather than a service VIP — that is what lets kube-proxy replacement work before
any CNI is running.

### LoadBalancer addresses

`192.168.0.15-34` is reserved outside the router's DHCP range and handed out by the
`lan-pool` `CiliumLoadBalancerIPPool`. Cilium answers ARP for these from whichever
node currently holds the lease, and fails over automatically.

| IP | Service |
| --- | --- |
| 192.168.0.15 | Homepage |
| 192.168.0.16 | Hubble UI |
| 192.168.0.17-34 | unallocated |

Pin an address by annotating the Service:

```yaml
annotations:
  io.cilium/lb-ipam-ips: "192.168.0.17"
```

Check who is announcing what with `kubectl get leases -n kube-system | grep l2announce`.

### Traefik

Traefik runs in an LXC on Proxmox (outside this cluster) and terminates TLS with
Cloudflare certs for `home.fullstackchef.dev`. Point it at the LoadBalancer IPs
above using the file provider:

```yaml
http:
  routers:
    homepage:
      rule: "Host(`homepage.home.fullstackchef.dev`)"
      entryPoints: [websecure]
      service: homepage
      tls:
        certResolver: cloudflare
  services:
    homepage:
      loadBalancer:
        servers:
          - url: "http://192.168.0.15:3000"
```

Homepage v1.x rejects requests whose `Host` header it does not recognise, so any
new hostname must also be added to `HOMEPAGE_ALLOWED_HOSTS` in its HelmRelease.

## Secrets

This repository is public, so **nothing unencrypted may be committed**. Secrets are
encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
and decrypted in-cluster by Flux — the encrypted file is safe to publish.

`.sops.yaml` encrypts only `data` and `stringData`, so a secret's name, namespace
and key names stay readable in diffs while the values do not.

Name secret files `*.sops.yaml` and they are encrypted automatically:

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

sops --encrypt --in-place apps/talos-cluster-1/foo/credentials.sops.yaml  # before committing
sops apps/talos-cluster-1/foo/credentials.sops.yaml                       # edit in place
```

> **Back up `~/.config/sops/age/keys.txt`.** It is gitignored and exists nowhere
> else. Lose it and every encrypted secret in this repo becomes unrecoverable.

The cluster needs the same key as a secret in `flux-system` (see Bootstrap below).

### What is safe to have public

The private LAN addresses here are RFC1918 and unroutable from the internet, and
`fullstackchef.dev` is already public in DNS. Neither is a meaningful disclosure.
The things that must never land in a commit are the kubeconfig, the Omni
`omniconfig.yaml`, talosconfig, PGP keys, and the age private key — all covered by
`.gitignore`.

## Bootstrap

```sh
export GITHUB_TOKEN=<pat-with-repo-scope>

flux bootstrap github \
  --owner=<you> --repository=talos-cluster \
  --branch=main --path=./clusters/talos-cluster-1 \
  --personal --public

# give Flux the age key so it can decrypt *.sops.yaml
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Cilium, metrics-server and Homepage were installed by hand during the initial
build. The HelmReleases adopt those existing releases because the release names
and namespaces match, so bootstrapping does not redeploy them.

## Access

| Service | URL |
| --- | --- |
| Homepage | <http://192.168.0.15:3000> |
| Hubble UI | <http://192.168.0.16> |

Or without going through the LAN addresses:

```sh
export KUBECONFIG=.kube/talos-cluster-1-kubeconfig.yaml
kubectl -n homepage    port-forward svc/homepage  3000:3000
kubectl -n kube-system port-forward svc/hubble-ui 8080:80
```

## Known gaps

- **No StorageClass.** Every node has only its OS disk, so nothing provisions PVCs.
  Homepage does not need one (its config lives in Git), but anything stateful will.
  Shared storage from TrueNAS Scale is planned — see below.
- **No etcd backups configured in Omni** (`backupconfiguration` is null). A manual
  snapshot lives outside this repo in `~/Documents/talos-backups/`. Configuring
  scheduled backups in Omni is worth doing.
- **`metrics-server` runs with `--kubelet-insecure-tls`.** Talos kubelets serve
  certificates it cannot verify unless kubelet server-cert rotation and an approver
  are enabled cluster-wide. An accepted trade-off on a trusted LAN.

### Planned: TrueNAS Scale storage

Once TrueNAS is attached, the usual options are:

- **democratic-csi** (`freenas-nfs` or `freenas-iscsi` driver) — a real CSI driver
  that talks to the TrueNAS API. Supports snapshots, expansion and per-PVC datasets.
  iSCSI gives `ReadWriteOnce` block volumes; NFS gives `ReadWriteMany`. This is the
  better long-term choice and belongs in `infrastructure/controllers/`.
- **nfs-subdir-external-provisioner** — much simpler, one NFS export carved into
  subdirectories, `ReadWriteMany` only, no snapshots. Fine if you just want PVCs to
  bind and do not care about storage features.

Either needs TrueNAS API credentials, which is exactly what the SOPS setup above is
for.
