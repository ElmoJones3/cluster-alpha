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

Local env lives in `mise.toml` (gitignored). `TALOSCONFIG` points at plaintext `secrets/talosconfig`. `talosctl` reads plaintext; git only sees `*.enc.yaml`.

```
cfg/controlplane.yaml           plaintext machine config — not committed
cfg/controlplane.enc.yaml       sops sidecar — committed
cfg/worker.yaml                 plaintext — not committed
cfg/worker.enc.yaml             sops sidecar — committed
secrets/talosconfig             plaintext talosctl creds — not committed
secrets/talosconfig.enc.yaml    sops sidecar — committed
.sops.yaml                      age recipient (public key)
scripts/cipher.sh               make encrypt / make decrypt
scripts/workers.sh              apply worker.yaml + tracked patches to WORKER_IP
patches/worker-local-pvs.yaml   non-secret worker patch for EPHEMERAL-backed local storage
k8s/local-path/                 pinned Local Path Provisioner + smoke test
```

```bash
export TALOSCONFIG=./secrets/talosconfig
# or pass --talosconfig=./secrets/talosconfig on each command
```

## Secrets (sops + age)

Plaintext under `cfg/` and `secrets/` is gitignored except `*.enc.yaml`. Public age key is in `.sops.yaml`. The private key is a **path on the machine** (`SOPS_AGE_KEY_FILE`), never in git.

```bash
make encrypt    # plaintext → *.enc.yaml (public recipient only; no private key)
make decrypt    # inverse; needs SOPS_AGE_KEY_FILE
```

Decrypt overwrites plaintext. No backup. Encrypt after you edit; commit the sidecars.

### Optional mise

`mise.toml` can export `SOPS_AGE_KEY_FILE`, `CONTROL_PLANE_IP`, `TALOSCONFIG`, etc. It is gitignored so each box has its own path.

`make decrypt` uses `mise x --` when `mise` is on PATH, so Make picks up that file. If mise is missing, the script runs as-is — export `SOPS_AGE_KEY_FILE` yourself first.

```bash
# with mise in this directory
make decrypt

# without mise
export SOPS_AGE_KEY_FILE=/path/to/age/keys.txt
make decrypt
```

Encrypt does not need the private key. A box with only this clone and no age identity cannot decrypt the Talos credentials; independently issued Talos or Kubernetes credentials are a separate access path.

Add a second machine as a recipient: put its public key in `.sops.yaml`, then `sops updatekeys` on the sidecars (or `make encrypt` from plaintext). Same private key copied to a second path also works; do not commit it.

Full workflow notes live in `scripts/cipher.sh`.

## Setup

Status against the [getting started](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started) steps. Workers skipped: no other boxes yet.

| Step | Status | Notes |
| --- | --- | --- |
| 1. Download the Talos Linux image | **done** | ISO from the [Image Factory](https://factory.talos.dev/) |
| 2. Boot your machine | **done** | Control plane only. Workers still pending. |
| 3. Store node IPs | **done** | `CONTROL_PLANE_IP=10.0.0.239` in `mise.toml`. No `WORKER_IP` yet. |
| 4. Unmount the ISO | **done** | So the machine boots from the installed NVMe after apply/reboot. |
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

### Next: steps 10–12 (still pending)

Cluster was last shut down from this laptop. Power the control plane on first.

```bash
talosctl kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
# or: talosctl kubeconfig ./secrets/kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
#      export KUBECONFIG=./secrets/kubeconfig

talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig health
kubectl get nodes
```

## Next steps

### a) Prepare and provision the next 5 workers

Each worker will use a directory on its existing Talos `EPHEMERAL` (`/var`) filesystem as the root for node-local PVCs. This does **not** repartition the NVMe, and `EPHEMERAL` must not be capped for this design.

The tracked [`patches/worker-local-pvs.yaml`](patches/worker-local-pvs.yaml) does two things:

- labels the Kubernetes node `local-pv=true`, so storage and workloads can select eligible workers;
- creates the directory-backed Talos user volume `local-pvs`, mounted at `/var/mnt/local-pvs`.

`volumeType: directory` has no `provisioning` block: `diskSelector`, `minSize`, `maxSize`, filesystem configuration, and encryption are invalid for this type. The directory inherits `EPHEMERAL` capacity. The intended ~128 GB per worker is therefore a **soft usage budget**, not a partition or quota.

[`scripts/workers.sh`](scripts/workers.sh) applies the generated worker config and this tracked patch together. On a new clone, run `make decrypt` first so `cfg/worker.yaml` exists.

- [ ] Boot each G5 from the same Talos ISO; note its maintenance-mode IP.
- [ ] Confirm the install disk on every box: `talosctl get disks --insecure --nodes <worker-ip>`.
- [ ] If a box differs from `/dev/nvme0n1`, give it a node-specific config/patch instead of applying the shared config blindly.
- [ ] Set space-separated `WORKER_IP` values in `mise.toml` or the environment.
- [ ] Run `./scripts/workers.sh`.
- [ ] Remove the ISO before the first reboot so the box boots from the installed NVMe.
- [ ] Wait until every worker is `Ready`, then verify the Talos mount and Kubernetes label.

```bash
WORKER_IP="10.0.0.240 10.0.0.241 10.0.0.242"
./scripts/workers.sh

talosctl --nodes $CONTROL_PLANE_IP get members
kubectl get nodes -o wide

talosctl --nodes <worker-ip> get volumestatus
talosctl --nodes <worker-ip> get mountstatus
talosctl --nodes <worker-ip> list /var/mnt/local-pvs
kubectl get node <worker-name> -o jsonpath='{.metadata.labels.local-pv}{"\n"}'
```

Do not re-run `talosctl bootstrap`. Workers join Kubernetes through their machine configuration; they do not join the etcd cluster.

Docs: [Getting Started](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started), [Talos architecture and `EPHEMERAL`](https://docs.siderolabs.com/talos/v1.13/learn-more/architecture), [directory-backed user volumes](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/user), and [configuration patches](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/patching).

### b) Install dynamic provisioning for local PVCs

[Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner) is an external dynamic provisioner that creates `hostPath`/`local` PV directories. It is not a CSI driver. The manifest in [`k8s/local-path/kustomization.yaml`](k8s/local-path/kustomization.yaml):

- pins upstream `v0.0.36` instead of tracking `master`;
- changes the upstream root from `/opt/local-path-provisioner` to `/var/mnt/local-pvs`;
- permits its helper Pods in the `local-path-storage` namespace;
- keeps `volumeBindingMode: WaitForFirstConsumer`;
- restricts provisioning to nodes labeled `local-pv=true`;
- uses `reclaimPolicy: Retain`, so deleting a PVC does not automatically erase database data;
- leaves `local-path` non-default, so workloads must request it explicitly.

Install only after the workers are `Ready`:

```bash
kubectl apply -k k8s/local-path
kubectl --namespace local-path-storage rollout status deployment/local-path-provisioner
kubectl get storageclass local-path
```

Smoke-test provisioning and the mount:

```bash
kubectl apply -f k8s/local-path/smoke-test.yaml
kubectl wait --for=condition=Ready pod/local-path-smoke --timeout=120s
kubectl exec local-path-smoke -- cat /data/result
kubectl get pvc,pv -o wide
```

The expected file is `local-path-ok`. Because the StorageClass retains data, switch only this test PV to `Delete` before cleanup:

```bash
SMOKE_PV=$(kubectl get pvc local-path-smoke -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$SMOKE_PV" --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
kubectl delete -f k8s/local-path/smoke-test.yaml
```

The PVC's requested size is Kubernetes metadata, not an enforced directory limit: Local Path Provisioner currently ignores capacity limits. Because this `hostPath` data shares `EPHEMERAL` with images, logs, kubelet, and containerd, monitor usage and node `DiskPressure` explicitly:

```bash
talosctl --nodes <worker-ip> usage /var/mnt/local-pvs --humanize --depth 2
kubectl get pvc,pv -A
kubectl describe node <worker-name>
```

Docs: [Talos local-storage guide](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage), [StorageClass binding and reclaim policies](https://kubernetes.io/docs/concepts/storage/storage-classes/), [`hostPath` accounting and disk pressure](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath), and [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).

### c) Place PostgreSQL, Elasticsearch, and Neo4j

`WaitForFirstConsumer` waits for Kubernetes to choose a node before creating the PV, but it does not guarantee that these three databases land on different workers. Assign the intended roles after the workers join:

```bash
kubectl label node <postgres-worker> storage-role=postgres
kubectl label node <elastic-worker> storage-role=elastic
kubectl label node <neo4j-worker> storage-role=neo4j
```

For each Helm chart or StatefulSet, ensure the resulting Pod template and PVC contain the equivalent of:

```yaml
# PostgreSQL example; use elastic or neo4j on the other workloads.
nodeSelector:
  storage-role: postgres

# In the PVC or volumeClaimTemplate:
storageClassName: local-path
```

Use `nodeSelector` or node affinity, not `spec.nodeName`: bypassing the scheduler can leave a `WaitForFirstConsumer` claim pending. Verify placement and binding after each deployment:

```bash
kubectl get pods -A -o wide
kubectl get pvc,pv -A -o wide
```

These volumes survive Pod replacement and node reboot, but remain bound to the worker where their directories live. If that worker is powered off or fails, its database Pod cannot mount the volume on another worker and will remain unavailable until the original node/data returns. This is persistence, not replication or HA; keep backups for anything that stops being disposable dev data.

Docs: [assigning Pods to nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/), [local-volume scheduling](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode), and [StatefulSet storage](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-storage).

### d) Second box works with the proper keys

Laptop/workstation #2, not a Talos node.

- [ ] Install `talosctl`, `sops`, optionally `mise`.
- [ ] Age **private** key on that box at whatever path you set (`SOPS_AGE_KEY_FILE`). Same key as this machine, or a new key listed as a recipient in `.sops.yaml`.
- [ ] Clone the repo. Working tree has sidecars only.
- [ ] `mise.toml` locally (gitignored) or `export SOPS_AGE_KEY_FILE=…`
- [ ] `make decrypt` — must produce plaintext without “SOPS_AGE_KEY_FILE is unset”.
- [ ] Control plane powered on: `talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig version`
- [ ] `talosctl --nodes $CONTROL_PLANE_IP get nodename` (or `health` once kubeconfig exists)
- [ ] Confirm `git status` does not list `cfg/controlplane.yaml`, `cfg/worker.yaml`, or `secrets/talosconfig`.

If decrypt works but `talosctl` fails, the key decrypted sops and the cluster is the separate problem (node off, wrong `CONTROL_PLANE_IP`, stale endpoints in `talosconfig`). If decrypt fails, the age identity does not match `.sops.yaml`.

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

# --- secrets ---
make encrypt                    # plaintext → *.enc.yaml
make decrypt                    # needs SOPS_AGE_KEY_FILE (mise x -- if mise exists)

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

**Control plane** — Node that runs etcd and the Kubernetes control plane (API server, scheduler, controller-manager). Needs to be reachable on **6443** (Kubernetes) and **50000** (Talos API). This cluster has one for now. Talos normally keeps ordinary workloads off control-plane nodes with a taint unless `cluster.allowSchedulingOnControlPlanes` is enabled; verify the live taints with `kubectl describe node`.

**Worker** — Node that runs workloads (kubelet + container runtime). Does not run etcd. Same Talos OS, different `machine.type`. A control-plane node can also run workloads only when its scheduling configuration and taints permit it.

**etcd** — Distributed key-value store Kubernetes uses as its source of truth (cluster state, object specs). `talosctl bootstrap` initializes it on the first control plane. Without a successful bootstrap, there is no Kubernetes API.

**Bootstrap** — One-shot: start etcd on a single control plane after machine config is applied and the node is up. Other control planes (when you have them) join that etcd cluster; they are not bootstrapped separately.

**Endpoint vs node** — An **endpoint** is who `talosctl` talks to (usually control planes). A **node** (`-n`) is who the request is for. Endpoints proxy to other members, so you do not retarget the endpoint just to inspect a worker.

**talosconfig** — Client certs and endpoints for the Talos API (`./secrets/talosconfig` here, or `~/.talos/config`). This is OS/cluster admin access, not `kubectl`. Git holds `secrets/talosconfig.enc.yaml`.

**sops / age** — Key-level encryption for YAML sidecars. Keys stay readable; values are `ENC[…]`. Age public key in `.sops.yaml`; private key only as `SOPS_AGE_KEY_FILE` on the machine.

**User volume** — Talos-managed local storage mounted at `/var/mnt/<name>`. Depending on `volumeType`, it can be a partition, a whole disk, or a directory backed by `EPHEMERAL`. It is not a Kubernetes `PersistentVolume` until a Pod uses it directly with `hostPath` or a provisioner creates PVs beneath it.

**kubeconfig** — Client creds for the Kubernetes API. Fetched with `talosctl kubeconfig` after bootstrap. Different file, different API (6443 vs 50000).

**Image Factory** — [factory.talos.dev](https://factory.talos.dev/): builds Talos ISOs/installers, including hardware-specific **system extensions** (NIC drivers, etc.) if a G5 box needs them.

**Omni** — Sidero’s hosted/self-hosted control plane for managing Talos machines across sites. Not used here; this is a DIY `talosctl` cluster.

**KubePrism** — On-node proxy so kubelets can always find the Kubernetes API locally even if the external endpoint is awkward. More relevant once there are multiple control planes.
