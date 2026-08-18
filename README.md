# alpha

First [Talos Linux](https://www.siderolabs.com/linux) cluster, on mini G5 boxes.

Following the [Getting Started](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started) guide for Talos v1.13. Single control plane for now; workers come later. For HA later, see [Production Notes](https://docs.siderolabs.com/talos/v1.13/getting-started/prodnotes).

## Cluster

| | |
| --- | --- |
| Name | `alpha` |
| Control plane | `10.0.0.239` |
| Kubernetes API | `https://10.0.0.239:6443` |
| Install disk | `/dev/nvme0n1` |
| Talos | v1.13.7 |
| Kubernetes | v1.36.2 |
| Layout | 1 control plane, 0 workers |

Local env lives in `mise.toml` (`CONTROL_PLANE_IP`, `CLUSTER_NAME`, `DISK_NAME`, `TALOSCONFIG`). Machine configs and `talosconfig` contain cluster PKI — encrypt before git (`sops`/`age`).

```
cfg/controlplane.yaml   machine config (control plane)
cfg/worker.yaml         machine config (workers)
secrets/talosconfig     talosctl client creds
scripts/workers.sh      apply worker.yaml to WORKER_IP
```

```bash
export TALOSCONFIG=./secrets/talosconfig
# or pass --talosconfig=./secrets/talosconfig on each command
```

## Setup

Status against the [getting started](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started) steps. Workers skipped: no other boxes yet.

| Step | Status | Notes |
| --- | --- | --- |
| 1. Download the Talos Linux image | **done** | ISO from the [Image Factory](https://factory.talos.dev/) |
| 2. Boot your machine | **done** | Control plane only. Workers still pending. |
| 3. Store node IPs | **done** | `CONTROL_PLANE_IP=10.0.0.239` in `mise.toml`. No `WORKER_IP` yet. |
| 4. Unmount the ISO | **done** | So install targets the NVMe, not the USB. |
| 5. Learn about installation disks | **done** | `talosctl get disks --insecure --nodes $CONTROL_PLANE_IP` → `nvme0n1` |
| 6. Generate cluster configuration | **done** | `cfg/controlplane.yaml`, `cfg/worker.yaml`, `secrets/talosconfig` |
| 7. Apply configurations | **done** | Control plane applied. Workers not applied. |
| 8. Set endpoints | **done** | `talosctl --talosconfig=./secrets/talosconfig config endpoints $CONTROL_PLANE_IP` |
| 9. Bootstrap etcd | **done** | Ran **once** on the single control plane. |
| 10. Get Kubernetes access | **pending** | `talosctl kubeconfig` |
| 11. Check cluster health | **pending** | `talosctl health` |
| 12. Verify node registration | **pending** | `kubectl get nodes` |

### Step 6 (done)

```bash
talosctl gen config $CLUSTER_NAME https://$CONTROL_PLANE_IP:6443 --install-disk /dev/$DISK_NAME
```

### Step 7 (done for the control plane)

```bash
talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file cfg/controlplane.yaml
```

`--insecure` is only for **maintenance mode** (node has no machine config yet). After this apply, Talos installs to disk and reboots. The maintenance API is then gone; later commands use `talosconfig`.

Workers, when the other G5s exist:

```bash
WORKER_IP="10.0.0.x 10.0.0.y"
./scripts/workers.sh
```

### Step 9 (done)

```bash
talosctl bootstrap --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
```

Ran **once** on the single control plane. Do not run it again on this cluster.

### Next: steps 10–12

```bash
# merge into ~/.kube/config
talosctl kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig

# or keep it separate
talosctl kubeconfig ./secrets/kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
export KUBECONFIG=./secrets/kubeconfig

talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig health
kubectl get nodes
```

## Cheatsheet

Most commands need `--nodes` / `-n`. **Endpoints** are how `talosctl` reaches the cluster (control planes). **Nodes** are the machines the call is *about*. After bootstrap, omit `--insecure`.

```bash
# --- identity ---
talosctl config info                          # active context, endpoints
talosctl version --nodes $CONTROL_PLANE_IP    # client + node Talos version
talosctl get nodename --nodes $CONTROL_PLANE_IP
talosctl get members --nodes $CONTROL_PLANE_IP  # cluster membership (Talos, not kubectl)

# --- is it up? ---
talosctl dashboard --nodes $CONTROL_PLANE_IP  # TUI: metrics, processes, logs (q to quit)
talosctl health --nodes $CONTROL_PLANE_IP     # waits until the cluster looks healthy
talosctl services --nodes $CONTROL_PLANE_IP   # like systemctl status, Talos-native
talosctl service kubelet restart --nodes $CONTROL_PLANE_IP

# --- logs (no SSH, no journalctl) ---
talosctl logs kubelet --nodes $CONTROL_PLANE_IP
talosctl logs kubelet -f --nodes $CONTROL_PLANE_IP
talosctl logs etcd --nodes $CONTROL_PLANE_IP
talosctl logs -k kube-apiserver --nodes $CONTROL_PLANE_IP  # Kubernetes static pod
talosctl dmesg --nodes $CONTROL_PLANE_IP                   # kernel ring buffer
talosctl dmesg -f --nodes $CONTROL_PLANE_IP

# --- hardware / disks ---
talosctl get disks --nodes $CONTROL_PLANE_IP
talosctl get disks --insecure --nodes $CONTROL_PLANE_IP    # maintenance mode only
talosctl get discoveredvolume --nodes $CONTROL_PLANE_IP
talosctl get systeminformation --nodes $CONTROL_PLANE_IP   # vendor, model, UUID
talosctl memory --nodes $CONTROL_PLANE_IP
talosctl get cpu --nodes $CONTROL_PLANE_IP

# --- network ---
talosctl get addresses --nodes $CONTROL_PLANE_IP
talosctl get links --nodes $CONTROL_PLANE_IP
talosctl get routes --nodes $CONTROL_PLANE_IP

# --- files (read-only; no shell) ---
talosctl list / --nodes $CONTROL_PLANE_IP
talosctl read /proc/cmdline --nodes $CONTROL_PLANE_IP

# --- kubernetes ---
talosctl kubeconfig --nodes $CONTROL_PLANE_IP   # merge kubeconfig
kubectl get nodes
kubectl get pods -A

# --- lifecycle (destructive ones last) ---
make reboot-all                 # workers first, then control plane
make shutdown-all               # full power-off; needs a button to come back
make shutdown-all YES=1         # skip the confirm prompt
talosctl reboot --nodes $CONTROL_PLANE_IP
talosctl shutdown --nodes $CONTROL_PLANE_IP
talosctl upgrade --nodes $CONTROL_PLANE_IP --image ghcr.io/siderolabs/installer:v1.13.7
# reset wipes the node and drops it back toward maintenance mode. Do not casually.
# talosctl reset --nodes $CONTROL_PLANE_IP --reboot
```

Full command list: [talosctl CLI reference](https://docs.siderolabs.com/talos/v1.13/reference/cli). Linux-admin mapping: [Talos for Linux admins](https://docs.siderolabs.com/talos/v1.13/learn-more/talos-for-linux-admins).

## Glossary

**Talos Linux** — A minimal, immutable OS from [Sidero Labs](https://www.siderolabs.com/) built only to run Kubernetes. No SSH, no shell, no package manager. You manage nodes through an API.

**Sidero Labs** — The company behind Talos and Omni.

**talosctl** — CLI for the Talos API. This is SSH + systemctl + journalctl for a machine that has none of those.

**Maintenance mode** — A node that has booted the ISO (RAM only) but has no machine config yet. The API is unauthenticated; `apply-config --insecure` is how you claim it. Anyone on the network can do that until a config is applied. The ISO does not write disks until then.

**Machine config** — Declarative YAML applied to a node (`cfg/controlplane.yaml` / `cfg/worker.yaml`). It is the OS install + cluster join + Kubernetes role in one document.

**Control plane** — Node that runs etcd and the Kubernetes control plane (API server, scheduler, controller-manager). Needs to be reachable on **6443** (Kubernetes) and **50000** (Talos API). This cluster has one for now.

**Worker** — Node that runs workloads (kubelet + container runtime). Does not run etcd. Same Talos OS, different `machine.type`. Optional for a first cluster; the control plane can also schedule pods unless you taint it.

**etcd** — Distributed key-value store Kubernetes uses as its source of truth (cluster state, object specs). `talosctl bootstrap` initializes it on the first control plane. Without a successful bootstrap, there is no Kubernetes API.

**Bootstrap** — One-shot: start etcd on a single control plane after machine config is applied and the node is up. Other control planes (when you have them) join that etcd cluster; they are not bootstrapped separately.

**Endpoint vs node** — An **endpoint** is who `talosctl` talks to (usually control planes). A **node** (`-n`) is who the request is for. Endpoints proxy to other members, so you do not retarget the endpoint just to inspect a worker.

**talosconfig** — Client certs and endpoints for the Talos API (`./secrets/talosconfig` here, or `~/.talos/config`). This is OS/cluster admin access, not `kubectl`.

**kubeconfig** — Client creds for the Kubernetes API. Fetched with `talosctl kubeconfig` after bootstrap. Different file, different API (6443 vs 50000).

**Image Factory** — [factory.talos.dev](https://factory.talos.dev/): builds Talos ISOs/installers, including hardware-specific **system extensions** (NIC drivers, etc.) if a G5 box needs them.

**Omni** — Sidero’s hosted/self-hosted control plane for managing Talos machines across sites. Not used here; this is a DIY `talosctl` cluster.

**KubePrism** — On-node proxy so kubelets can always find the Kubernetes API locally even if the external endpoint is awkward. More relevant once there are multiple control planes.
