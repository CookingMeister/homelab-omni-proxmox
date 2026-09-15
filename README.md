# homelab-omni-proxmox

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
| **Storage** | local-path-provisioner (node-local) |
| **Apps** | linkding |
| **Secrets** | SOPS + age |
| **Hypervisor** | Proxmox VE 9.2 |

## Topology

| Node | IP | Role | vCPU | RAM | Disk |
| --- | --- | --- | --- | --- | --- |
| talos-3z8-t6d | 192.168.0.77 | control-plane | 4 | 16 GB | 64 GB |
| talos-05t-4cw | 192.168.0.78 | control-plane | 4 | 16 GB | 64 GB |
| talos-zdx-y3b | 192.168.0.79 | control-plane | 4 | 16 GB | 64 GB |

All three nodes are control planes running etcd, so the cluster tolerates the loss
of one (quorum 2 of 3). They are untainted, so workloads schedule across all three
and there are no dedicated worker nodes.

Addresses are **static**, set per machine by Omni config patches
(`500-static-ip-77` / `-78` / `-79`) rather than by DHCP reservation:

```yaml
machine:
  network:
    interfaces:
      - interface: eth0
        dhcp: false
        addresses: ["192.168.0.78/24"]
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.0.1
    nameservers: ["192.168.0.1"]
```

Each patch is scoped to one machine with the label
`omni.sidero.dev/machine: <machine-uuid>`; verify scoping with
`omnictl get clustermachineconfigpatch <uuid>` before applying, since a
mis-scoped patch would assign one address to every node.

> Omni assigns node hostnames and reassigns them whenever a machine is
> reprovisioned. Never pin a workload to a node by name — use labels.

## Architecture

```text
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

```text
clusters/talos-cluster-1/   Flux entrypoint — Kustomizations for the trees below
infrastructure/controllers/ Cluster-wide controllers (Cilium, metrics-server, local-path-provisioner)
infrastructure/configs/     Cluster-wide config depending on those controllers
apps/talos-cluster-1/       Workloads (Homepage, linkding)
k9s/                        Local k9s config — not applied to the cluster
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
| 192.168.0.17 | linkding |
| 192.168.0.18-34 | available |

Pin an address by annotating the Service:

```yaml
annotations:
  io.cilium/lb-ipam-ips: "192.168.0.17"
```

The L2 announcement policy matches `^eth[0-9]+$`, so announcements stay on the LAN
NIC and are never sent into Omni's `siderolink` WireGuard interface.

### Publishing a service through Traefik

Add a router and service to Traefik's file provider pointing at the pinned IP.
Traefik reads `/etc/traefik/conf.d/` as **one** configuration, so a parse error in any
file there drops every router in the directory — merge into the existing `routers:`
and `services:` blocks rather than appending, and validate before reloading:

```sh
python3 -c "import yaml;yaml.safe_load(open('/etc/traefik/conf.d/services.yml'))"
systemctl restart traefik
```

```yaml
http:
  routers:
    homepage:
      rule: "Host(`homepage.home.fullstackchef.dev`)"
      entryPoints: [websecure]
      service: homepage
      tls:
        certResolver: letsencrypt
  services:
    homepage:
      loadBalancer:
        servers:
          - url: "http://192.168.0.15:3000"
```

Homepage rejects requests whose `Host` header it does not recognise, so any new
hostname must also be added to `HOMEPAGE_ALLOWED_HOSTS` in its HelmRelease. The
cluster dashboard answers to `k8s.home.fullstackchef.dev`:

```yaml
http:
  routers:
    k8s-homepage:
      rule: "Host(`k8s.home.fullstackchef.dev`)"
      entryPoints: [websecure]
      service: k8s-homepage
      tls:
        certResolver: letsencrypt
  services:
    k8s-homepage:
      loadBalancer:
        servers:
          - url: "http://192.168.0.15:3000"
```

## Storage

[local-path-provisioner](https://github.com/rancher/local-path-provisioner) provides
the `local-path` StorageClass. A volume is a directory on one node's OS disk, created
on demand by a helper pod. There is no replication and no shared filesystem — this is
the smallest thing that makes a PVC bind, not real storage.

Three consequences follow from that, and all three are deliberate:

- **`local-path` is not the cluster default.** A workload gets local storage only by
  naming the class in its PVC. Nothing lands on a node-bound volume by forgetting to
  choose. When democratic-csi arrives it becomes the default and nothing already
  running moves.
- **`volumeBindingMode: WaitForFirstConsumer`.** The provisioner cannot move a volume
  after it exists, so the scheduler picks the node first. Once bound, the pod is
  pinned to that node for the life of the volume — if the node is down, the pod stays
  `Pending` rather than starting elsewhere with an empty disk.
- **`reclaimPolicy: Retain`.** Deleting a PVC leaves the directory in place instead of
  erasing it. The cost is an orphaned directory to remove by hand after a genuine
  deletion, which is the cheaper mistake.

### Why the path is under /var

Talos has a read-only root filesystem. The chart's default, `/opt/local-path-provisioner`,
is not writable and the helper pod fails on `mkdir`. Volumes live at
`/var/local-path-provisioner` instead, on the ephemeral partition.

> `/var` survives reboots and Talos upgrades. It does **not** survive `talosctl reset`
> or a reprovision from Omni — both wipe the ephemeral partition. Anything here that
> matters needs a backup outside the cluster.

### Pod Security

Talos enforces the Pod Security `baseline` profile cluster-wide, and `baseline` forbids
`hostPath` volumes. The helper pod mounts the node filesystem as a hostPath to create
and remove volume directories, so provisioning fails with an admission error unless its
namespace is exempted:

```yaml
metadata:
  name: local-path-storage
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

The exemption is scoped to that one namespace. Workloads that merely *consume* a
volume need nothing — a PVC-backed hostPath volume is not a hostPath volume in the pod
spec, so `linkding` runs under `baseline` unchanged.

### Checking it

```sh
kubectl get storageclass
kubectl get pv,pvc -A
kubectl -n local-path-storage logs deploy/local-path-provisioner
```

A PVC stuck in `Pending` with no events is normal until a pod consumes it — that is
`WaitForFirstConsumer` working, not a failure.

## Dashboard

Homepage is configured entirely in Git, in its HelmRelease under `config`. Services
are listed under `services`, grouped, with the group order set by `layout` in
`settingsString`.

Homepage's Kubernetes service discovery reads `Ingress`, Traefik `IngressRoute` and
Gateway API `HTTPRoute` objects — **not** plain `Service` objects. TLS terminates at a
Traefik instance outside the cluster and nothing in here creates those objects, so
there is nothing for discovery to find and the dashboard is maintained by hand. That
is a deliberate consequence of keeping the reverse proxy outside the cluster.

The Kubernetes **widgets** (cluster and node CPU/memory) are unrelated to discovery and
do work: they need `config.kubernetes.mode: cluster`, the chart's RBAC, and
metrics-server.

## Bookmarks

[linkding](https://github.com/sissbruecker/linkding) is a bookmark manager — tags,
full-text search, a browser extension and a REST API. It was chosen over
[karakeep](https://karakeep.app/) deliberately: karakeep wants a Meilisearch index, a
headless Chrome for page archiving and an AI backend for tagging, which is four
workloads and three kinds of state where linkding is one container and one SQLite
file. On a cluster whose only storage is a directory on a node's disk, that difference
decides it. Revisit karakeep once there is real storage and a reason to want
full-page archiving.

State lives on a 2 Gi `local-path` volume at `/etc/linkding/data`, so the pod is
pinned to whichever node bound it. **There is no backup.** Use the export in
Settings → General before doing anything to that node.

### The admin user

The container runs `createsuperuser` on first start when `LD_SUPERUSER_NAME` and
`LD_SUPERUSER_PASSWORD` are both set. They come from `superuser.sops.yaml` alongside
the HelmRelease, encrypted with SOPS like every other secret here.

> These take effect **once**. After the user exists the container ignores them, so
> editing the encrypted file does not rotate the password — change it in the web UI
> and update the file to match.

### Publishing it

linkding is a Django app, so every login and every bookmark save is a POST checked
against `CSRF_TRUSTED_ORIGINS`. Traefik terminates TLS and forwards the original
`Host`, so the browser sends an `https://` Origin that Django does not recognise. The
symptom is specific and easy to misread: the page loads fine and looks healthy, then
the login form returns "CSRF verification failed". Set the public URL, with its
scheme, in `LD_CSRF_TRUSTED_ORIGINS` in the HelmRelease — it is the same class of
gotcha as `HOMEPAGE_ALLOWED_HOSTS`.

Then add the router to Traefik's file provider, merging into the existing blocks:

```yaml
http:
  routers:
    linkding:
      rule: "Host(`links.home.fullstackchef.dev`)"
      entryPoints: [websecure]
      service: linkding
      tls:
        certResolver: letsencrypt
  services:
    linkding:
      loadBalancer:
        servers:
          - url: "http://192.168.0.17:9090"
```

### The Homepage widget

Homepage ships a `linkding` widget showing bookmark counts. It needs an API token
generated in linkding's own settings, which cannot be done before the app is running,
so it is not configured here. Add the token as a SOPS-encrypted secret and reference
it from the Homepage HelmRelease if you want it.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) raises PRs for Helm chart updates, driven by
`renovate.json`. It scans `clusters/`, `infrastructure/` and `apps/` with the `flux`
manager, which reads chart versions straight out of the HelmReleases.

| Update | Behaviour |
| --- | --- |
| Patch | Automerged after a 3-day cooling-off period |
| Minor (metrics-server, homepage, linkding) | Grouped into one PR for review |
| local-path-provisioner (any) | Never automerged, 7-day minimum age |
| Cilium (any) | Never automerged, 7-day minimum age, own PR |
| `clusters/*/flux-system/**` | Ignored |

A `customManagers` regex entry also tracks container images pinned inside HelmRelease
values, marked with a `# renovate: image=...` comment. This matters because the flux
manager only sees **chart** versions — an image pinned to work around a stale chart is
invisible to it otherwise. Homepage is pinned this way: chart `2.1.0` is the newest
published but still ships application v1.2.0, several releases behind upstream.

Cilium is singled out because it is the CNI and the kube-proxy replacement — a bad
upgrade takes cluster networking with it. The `flux-system` directory is excluded
because Flux's own controllers are upgraded by re-running `flux bootstrap`, which
rewrites `gotk-components.yaml`; letting Renovate edit it too would put the two in
conflict.

Renovate opens a **Dependency Dashboard** issue listing everything it is tracking and
anything it has deliberately held back.

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
  --owner=CookingMeister --repository=homelab-omni-proxmox \
  --branch=main --path=./clusters/talos-cluster-1 \
  --personal --private=false

# give Flux the age key so it can decrypt *.sops.yaml
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

## Access

| Service | Address |
| --- | --- |
| Homepage | <https://k8s.home.fullstackchef.dev> · <http://192.168.0.15:3000> |
| Hubble UI | <http://192.168.0.16> |
| linkding | <https://links.home.fullstackchef.dev> · <http://192.168.0.17:9090> |

> `homepage.home.fullstackchef.dev` is a **separate, pre-existing Homepage** outside
> this cluster. The cluster dashboard is `k8s.home.fullstackchef.dev`.

Or via port-forward:

```sh
export KUBECONFIG=.kube/talos-cluster-1-kubeconfig.yaml
kubectl -n homepage    port-forward svc/homepage  3000:3000
kubectl -n kube-system port-forward svc/hubble-ui 8080:80
kubectl -n linkding    port-forward svc/linkding  9090:9090
```

## Operations

### Node maintenance

Every node is an etcd member, so **only one node may be down at a time** — quorum is
2 of 3. Take the etcd leader last, so there is a single leader election at the end:

```sh
# find the leader (LEADER column) and the current lease holders
talosctl -n 192.168.0.77,192.168.0.78,192.168.0.79 etcd status
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

### Changing a node's IP

Edit that machine's `500-static-ip-*` patch and apply it. Talos reboots the node onto
the new address and **updates its own etcd peer URL** — no reprovision needed. The node
is `NotReady` for two to three minutes. Do one node at a time; quorum is 2 of 3.

Two pieces of state do **not** follow the node, and both must be checked afterwards:

```sh
# 1. Cilium keeps the old address in its node registry
kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,ADDRESSES:.spec.addresses[*].ip
kubectl -n kube-system rollout restart ds/cilium     # fix

# 2. The kubernetes Service endpoints keep the old apiserver addresses
kubectl get endpoints kubernetes -n default
```

Both fail in ways that mislead:

- **Stale `CiliumNode`** breaks only cross-node traffic. A LoadBalancer service whose
  pod happens to run on the same node that answers its ARP keeps working, so it looks
  like one service broke rather than the CNI.
- **Stale endpoints** leave `10.96.0.1` round-robining across dead apiservers, so
  in-cluster clients fail a fraction of requests. A dashboard flickers between data and
  an API error rather than going down. `kubectl` never shows this, because it reaches
  the apiserver through Omni's proxy rather than the ClusterIP.

The apiserver's lease reconciler does repair the endpoints on its own, logging
`Resetting endpoints for master service "kubernetes"`, but only on its next restart.

> When inspecting Cilium's backends, keep the context flag — `cilium-dbg service list`
> prints backends on continuation lines, and grepping without `-A` shows only the first,
> which makes a stale list look correct:
> `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A4 10.96.0.1`

### Browsing the cluster with k9s

[k9s](https://k9scli.io/) is a terminal UI over the same API — handy for watching a
reconcile happen rather than re-running `flux get`. Nothing here depends on it.

```sh
k9s                  # current context
k9s --context bob    # a different cluster, without changing your default
```

`:ctx` switches context **inside k9s only**, leaving your shell's context untouched —
which is the safe way to look at another cluster, since `kubectl config use-context`
is persistent and global.

`k9s/aliases.yaml` in this repo adds shortcuts for the resources this cluster actually
uses. Install it by copying into k9s's config directory (`k9s info` prints the path;
on Linux it is `~/.config/k9s`):

| Alias | Resource |
| --- | --- |
| `:ks` | Flux Kustomizations |
| `:hr` / `:hrepo` / `:hchart` | HelmReleases / repositories / charts |
| `:grepo` | GitRepositories |
| `:cnode` | CiliumNodes — the registry that goes stale after an IP change |
| `:lbpool` / `:l2pol` | LoadBalancer IP pool / L2 announcement policy |
| `:cep` / `:cnp` | Cilium endpoints / network policies |

Navigation: `/` filters, `Esc` backs out, `?` lists keybindings, `:q` quits. On a
selected row — `l` logs, `d` describe, `y` YAML, `s` shell.

> k9s honours `KUBECONFIG` like kubectl does. If it is exported, k9s sees only that
> file and `:ctx` lists one context instead of all of them.

### Health checks

```sh
talosctl -n 192.168.0.77 etcd members
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
flux get all -A
kubectl top nodes
```

## Roadmap

- [ ] **Shared persistent storage.** `local-path` covers single-replica workloads but
      pins each one to a node with no replication and no backup. Shared storage from
      TrueNAS Scale is planned, via `democratic-csi` — iSCSI for block volumes with
      snapshots and expansion, NFS for `ReadWriteMany`. Note that SQLite over NFS is a
      corruption risk, so linkding wants the iSCSI class, not the NFS one.
- [ ] **Scheduled etcd backups in Omni.**
- [ ] **Monitoring stack.** Prometheus and Grafana, with Cilium and Hubble metrics.
- [ ] **Gateway API via Cilium**, which would give in-cluster L7 routing and make
      Homepage's `HTTPRoute` service discovery usable instead of a hand-kept list.

## Notes

**Proxmox memory ballooning is disabled on these VMs, and must stay that way.**
Kubelet reads node capacity once at startup and never revises it, so a node that
boots with a partly-inflated balloon registers less memory than it has and the
scheduler never uses the difference. Ballooning can also reclaim memory the kubelet
believes is available, which surfaces as OOM kills rather than an obvious capacity
problem. After any memory change, reboot the node and confirm the two views agree:

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,CAPACITY:.status.capacity.memory
talosctl -n <ip> memory
```

`metrics-server` runs with `--kubelet-insecure-tls`. Talos kubelets serve
certificates it cannot verify unless kubelet server-certificate rotation and an
approver are enabled cluster-wide — an accepted trade-off on a trusted LAN.
