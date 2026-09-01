# talos-cluster

A three-node [Talos Linux](https://www.talos.dev/) Kubernetes cluster running on
Proxmox VE 9.2, managed declaratively end to end: the machines by
[Sidero Omni](https://omni.sidero.dev/), everything inside the cluster by
[Flux CD](https://fluxcd.io/) from this repository.

No SSH, no `kubectl apply` by hand. Talos has no shell and no package manager — the
OS is an API. Anything running in the cluster is described here in Git, and a change
is a commit.

| | |
| --- | --- |
| **OS** | Talos Linux v1.13.5 |
| **Kubernetes** | v1.36.2 |
| **Machine management** | Sidero Omni |
| **GitOps** | Flux CD |
| **CNI** | Cilium 1.20.1 (eBPF, kube-proxy replacement) |
| **Load balancing** | Cilium L2 announcements |
| **Observability** | Hubble, metrics-server |
| **Dashboard** | Homepage |
| **Secrets** | SOPS + age |
| **Hypervisor** | Proxmox VE 9.2 |

## Topology

| Node | IP | Role | vCPU | RAM | Disk |
| --- | --- | --- | --- | --- | --- |
| talos-05t-4cw | 192.168.0.224 | control-plane | 4 | 8 GB | 34 GB |
| talos-zdx-y3b | 192.168.0.246 | control-plane | 4 | 8 GB | 64 GB |
| talos-3z8-t6d | 192.168.0.77 | control-plane | 4 | 8 GB | 64 GB |

All three nodes are control planes running etcd, so the cluster tolerates the loss
of one (quorum 2 of 3). They are untainted, so workloads schedule across all three
and there are no dedicated worker nodes.

> Omni assigns node hostnames and reassigns them whenever a machine is
> reprovisioned. Never pin a workload to a node by name — use labels.

## Architecture

```
        Internet
           │
      Cloudflare  (DNS + TLS)
           │
      Hetzner VPS
           │
   ┌───────┴────────┐
   │  Traefik LXC   │  home.fullstackchef.dev
   │  (Proxmox)     │
   └───────┬────────┘
           │  routes to fixed LAN IPs
   ┌───────┴──────────────────────────────┐
   │  Cilium LoadBalancer  192.168.0.15+  │
   ├──────────────────────────────────────┤
   │  talos-05t-4cw  talos-zdx-y3b  ...   │
   │  Talos + Kubernetes on Proxmox VE    │
   └──────────────────────────────────────┘
```

TLS terminates at Traefik, which runs outside the cluster in a Proxmox LXC. The
cluster exposes services as `LoadBalancer` on the LAN and Traefik proxies to those
addresses, so there is no in-cluster ingress controller.

## Repository layout

```
clusters/talos-cluster-1/   Flux entrypoint — Kustomizations for the trees below
infrastructure/controllers/ Cluster-wide controllers (Cilium, metrics-server)
infrastructure/configs/     Cluster-wide config depending on those controllers
apps/talos-cluster-1/       Workloads (Homepage)
```

Reconcile order is `infra-controllers` → `infra-configs`, with `apps` depending on
`infra-controllers`.

## Networking

Cilium provides the CNI and fully replaces kube-proxy — service routing is eBPF, and
no `kube-proxy` DaemonSet or iptables service chains exist. This requires Talos to
ship neither a CNI nor kube-proxy, set through an Omni config patch:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

Cilium reaches the API server through Talos **KubePrism** on `localhost:7445`, a
node-local API server load balancer. That is what lets kube-proxy replacement work
before any CNI is running — there is no chicken-and-egg on the service VIP.

### LoadBalancer addresses

`192.168.0.15-34` is reserved outside the router's DHCP range and served by the
`lan-pool` `CiliumLoadBalancerIPPool`. Cilium answers ARP for these addresses from
whichever node holds the lease, and fails over automatically.

| IP | Service |
| --- | --- |
| 192.168.0.15 | Homepage |
| 192.168.0.16 | Hubble UI |
| 192.168.0.17-34 | available |

Pin an address by annotating the Service:

```yaml
annotations:
  io.cilium/lb-ipam-ips: "192.168.0.17"
```

The L2 announcement policy matches `^eth[0-9]+$`, so announcements stay on the LAN
NIC and are never sent into Omni's `siderolink` WireGuard interface.

### Publishing a service through Traefik

Add a router and service to Traefik's file provider pointing at the pinned IP:

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

Homepage rejects requests whose `Host` header it does not recognise, so any new
hostname must also be added to `HOMEPAGE_ALLOWED_HOSTS` in its HelmRelease.

## Secrets

This repository is public. Secrets are encrypted with
[SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age)
and decrypted in-cluster by Flux, so the encrypted files are safe to publish.

`.sops.yaml` encrypts only `data` and `stringData` — a secret's name, namespace and
key names stay readable in diffs while the values do not.

Files named `*.sops.yaml` are encrypted automatically:

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

sops --encrypt --in-place apps/talos-cluster-1/foo/credentials.sops.yaml
sops apps/talos-cluster-1/foo/credentials.sops.yaml   # edit in place
```

> The age private key lives only at `~/.config/sops/age/keys.txt` and is gitignored.
> Back it up. Without it, every encrypted secret here is unrecoverable.

The kubeconfig, Omni `omniconfig.yaml`, talosconfig and PGP keys are gitignored and
must never be committed.

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

## Access

| Service | Address |
| --- | --- |
| Homepage | <http://192.168.0.15:3000> |
| Hubble UI | <http://192.168.0.16> |

Or via port-forward:

```sh
export KUBECONFIG=.kube/talos-cluster-1-kubeconfig.yaml
kubectl -n homepage    port-forward svc/homepage  3000:3000
kubectl -n kube-system port-forward svc/hubble-ui 8080:80
```

## Operations

### Node maintenance

Every node is an etcd member, so **only one node may be down at a time** — quorum is
2 of 3. Take the etcd leader last, so there is a single leader election at the end:

```sh
# find the leader (LEADER column) and the current lease holders
talosctl -n 192.168.0.224,192.168.0.246,192.168.0.77 etcd status
kubectl get leases -n kube-system | grep l2announce
```

Then, per node:

```sh
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
talosctl -n <ip> shutdown
# perform maintenance, power on
kubectl uncordon <node>
```

Before moving to the next node, confirm all three etcd members report the same
`RAFT INDEX` with no errors. A node reports `Ready` before etcd has caught up, so
`kubectl get nodes` alone is not a sufficient check.

### Health checks

```sh
talosctl -n 192.168.0.224 etcd members
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
flux get all -A
kubectl top nodes
```

## Roadmap

- [ ] **Persistent storage.** There is no StorageClass — each node has only its OS
      disk, so nothing provisions PVCs and stateful workloads cannot run. Shared
      storage from TrueNAS Scale is planned, via `democratic-csi` (NFS for
      `ReadWriteMany`, iSCSI for block volumes with snapshots and expansion).
- [ ] **Scheduled etcd backups in Omni.**
- [ ] **Monitoring stack.** Prometheus and Grafana, with Cilium and Hubble metrics.
- [ ] **Automated dependency updates** via Renovate.
- [ ] **Kubernetes service discovery in Homepage**, so annotated services appear on
      the dashboard automatically.

## Notes

`metrics-server` runs with `--kubelet-insecure-tls`. Talos kubelets serve
certificates it cannot verify unless kubelet server-certificate rotation and an
approver are enabled cluster-wide — an accepted trade-off on a trusted LAN.
