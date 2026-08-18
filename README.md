# alpha

A [Talos Linux](https://www.siderolabs.com/linux) cluster, running on mini G5 boxes in my basement. It is a local Kubernetes environment for development, with node-local storage planned for PostgreSQL, Elasticsearch, and Neo4j.

The cluster follows the [Talos v1.13 Getting Started guide](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started). It has one control plane for now. See the Talos [production notes](https://docs.siderolabs.com/talos/v1.13/getting-started/prodnotes) before adding control-plane redundancy.

## Contents

- [About](#about)
- [Cluster](#cluster)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Roadmap](#roadmap)
- [Operations](#operations)
- [Glossary](#glossary)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## About

This repository holds the cluster configuration, encrypted credentials, worker patches, Kubernetes manifests, and the runbook used to operate the cluster. Secrets are committed only as sops-encrypted sidecars.

Each worker will expose a directory on Talos `EPHEMERAL` storage for local PersistentVolumes. Rancher Local Path Provisioner will create volumes there on demand. The target of about 128 GB, roughly half of each worker's disk, is an operating budget rather than a filesystem quota.

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

## Repository layout

| Path | Purpose | Committed |
| --- | --- | --- |
| `cfg/controlplane.yaml` | Plaintext control-plane machine config | No |
| `cfg/controlplane.enc.yaml` | Encrypted control-plane config | Yes |
| `cfg/worker.yaml` | Plaintext worker machine config | No |
| `cfg/worker.enc.yaml` | Encrypted worker config | Yes |
| `secrets/talosconfig` | Plaintext `talosctl` credentials | No |
| `secrets/talosconfig.enc.yaml` | Encrypted `talosctl` credentials | Yes |
| `.sops.yaml` | Public age recipient | Yes |
| `scripts/cipher.sh` | Encryption and decryption workflow | Yes |
| `scripts/workers.sh` | Applies the worker config and tracked patches to `WORKER_IP` | Yes |
| `patches/worker-local-pvs.yaml` | Worker label and `EPHEMERAL`-backed local-storage patch | Yes |
| `k8s/local-path/` | Pinned Local Path Provisioner and smoke test | Yes |

Local environment settings live in `mise.toml`, which is gitignored. `TALOSCONFIG` points to the plaintext `secrets/talosconfig`; `talosctl` reads that file while git sees only `*.enc.yaml`.

## Requirements

- `talosctl` and `kubectl` for cluster administration
- `sops` and `age` for encrypted configuration
- `make` for the encryption and lifecycle shortcuts
- `mise` if you want per-machine environment variables loaded automatically

## Getting started

### Environment

Set `TALOSCONFIG` in your shell or pass it to each command:

```bash
export TALOSCONFIG=./secrets/talosconfig
# or pass --talosconfig=./secrets/talosconfig on each command
```

`mise.toml` can export `SOPS_AGE_KEY_FILE`, `CONTROL_PLANE_IP`, `TALOSCONFIG`, and the other local values. It stays out of git so each admin machine can use its own paths.

### Secrets

Plaintext files under `cfg/` and `secrets/` are gitignored except for `*.enc.yaml`. The public age key is in `.sops.yaml`. The private key is a path on the admin machine, supplied through `SOPS_AGE_KEY_FILE`, and never belongs in git.

```bash
make encrypt    # plaintext to *.enc.yaml; needs only the public recipient
make decrypt    # *.enc.yaml to plaintext; needs SOPS_AGE_KEY_FILE
```

Decryption overwrites the plaintext files without making a backup. Encrypt after editing, then commit the sidecars.

`make decrypt` runs through `mise x --` when `mise` is available, which loads the local environment. Without `mise`, export the key path yourself:

```bash
# with mise in this directory
make decrypt

# without mise
export SOPS_AGE_KEY_FILE=/path/to/age/keys.txt
make decrypt
```

Encryption does not need the private key. A machine with only this clone and no matching age identity cannot decrypt the Talos credentials. Independently issued Talos or Kubernetes credentials are a separate access path.

To add another age identity, add its public key to `.sops.yaml`, then run `sops updatekeys` on the sidecars or `make encrypt` from plaintext. Copying the existing private key to a second machine also works, but do not commit it. Full workflow notes are in `scripts/cipher.sh`.

### Current build status

Workers have not been provisioned because the other boxes are not in the cluster yet.

| Step | Status | Notes |
| --- | --- | --- |
| 1. Download the Talos Linux image | **done** | ISO from the [Image Factory](https://factory.talos.dev/) |
| 2. Boot your machine | **done** | Control plane only. Workers are still pending. |
| 3. Store node IPs | **done** | `CONTROL_PLANE_IP=10.0.0.239` in `mise.toml`. No `WORKER_IP` yet. |
| 4. Unmount the ISO | **done** | The machine must boot from the installed NVMe after apply and reboot. |
| 5. Learn about installation disks | **done** | `talosctl get disks --insecure --nodes $CONTROL_PLANE_IP` returned `nvme0n1`. |
| 6. Generate cluster configuration | **done** | Created `cfg/controlplane.yaml`, `cfg/worker.yaml`, and `secrets/talosconfig`. |
| 7. Apply configurations | **done** | Control plane applied. Workers not applied. |
| 8. Set endpoints | **done** | Ran `talosctl --talosconfig=./secrets/talosconfig config endpoints $CONTROL_PLANE_IP`. |
| 9. Bootstrap etcd | **done** | Ran once on the single control plane. |
| 10. Get Kubernetes access | **pending** | Run `talosctl kubeconfig`. |
| 11. Check cluster health | **pending** | Run `talosctl health`. |
| 12. Verify node registration | **pending** | Run `kubectl get nodes`. |

The cluster configuration was generated with:

```bash
talosctl gen config $CLUSTER_NAME https://$CONTROL_PLANE_IP:6443 --install-disk /dev/$DISK_NAME
```

The control-plane configuration was applied with:

```bash
talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file cfg/controlplane.yaml
```

`--insecure` is only for maintenance mode, before a node has a machine configuration. Applying the configuration installs Talos to disk and reboots the node. Later commands use `talosconfig` because the unauthenticated maintenance API is gone.

Workers will use the shared script when the remaining G5s are ready:

```bash
WORKER_IP="10.0.0.x 10.0.0.y"
./scripts/workers.sh
```

etcd was bootstrapped with:

```bash
talosctl bootstrap --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
```

That command runs once per cluster. Do not run it again on `alpha`.

### Finish the control-plane setup

The cluster was last shut down from this laptop. Power on the control plane first, then finish steps 10 through 12:

```bash
talosctl kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
# or: talosctl kubeconfig ./secrets/kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig
#      export KUBECONFIG=./secrets/kubeconfig

talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig health
kubectl get nodes
```

## Roadmap

### 1. Provision five workers

Each worker will use a directory on its existing Talos `EPHEMERAL` filesystem (`/var`) as the root for node-local PVCs. This design does not repartition the NVMe, and `EPHEMERAL` must remain uncapped.

[`patches/worker-local-pvs.yaml`](patches/worker-local-pvs.yaml) labels the Kubernetes node `local-pv=true` and creates the directory-backed Talos user volume `local-pvs` at `/var/mnt/local-pvs`.

`volumeType: directory` has no `provisioning` block. Fields such as `diskSelector`, `minSize`, `maxSize`, filesystem configuration, and encryption are invalid for this volume type. The directory inherits the capacity of `EPHEMERAL`, so the planned 128 GB per worker is a soft usage budget rather than a partition or quota.

[`scripts/workers.sh`](scripts/workers.sh) applies the generated worker config and the tracked patch together. Run `make decrypt` first on a fresh clone so `cfg/worker.yaml` exists.

- [ ] Boot each G5 from the same Talos ISO and note its maintenance-mode IP.
- [ ] Check the install disk on every box with `talosctl get disks --insecure --nodes <worker-ip>`.
- [ ] If a box does not use `/dev/nvme0n1`, give it a node-specific config or patch instead of applying the shared config.
- [ ] Set space-separated `WORKER_IP` values in `mise.toml` or the environment.
- [ ] Run `./scripts/workers.sh`.
- [ ] Remove the ISO before the first reboot so the box starts from the installed NVMe.
- [ ] Wait for every worker to become `Ready`, then check the Talos mount and Kubernetes label.

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

Do not run `talosctl bootstrap` again. Workers join Kubernetes through their machine configuration; they do not join etcd.

References: [Getting Started](https://docs.siderolabs.com/talos/v1.13/getting-started/getting-started), [Talos architecture and `EPHEMERAL`](https://docs.siderolabs.com/talos/v1.13/learn-more/architecture), [directory-backed user volumes](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/user), and [configuration patches](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/patching).

### 2. Install local PVC provisioning

[Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner) is an external dynamic provisioner that creates `hostPath` or `local` PV directories. It is not a CSI driver.

[`k8s/local-path/kustomization.yaml`](k8s/local-path/kustomization.yaml) pins upstream `v0.0.36` instead of tracking `master`, changes the default root from `/opt/local-path-provisioner` to `/var/mnt/local-pvs`, permits helper Pods in the `local-path-storage` namespace, and restricts provisioning to nodes labeled `local-pv=true`. The `local-path` StorageClass uses `WaitForFirstConsumer` and `Retain`. Deleting a PVC therefore does not automatically erase its database data. The class is not the default, so workloads must request it by name.

Install the provisioner after the workers are `Ready`:

```bash
kubectl apply -k k8s/local-path
kubectl --namespace local-path-storage rollout status deployment/local-path-provisioner
kubectl get storageclass local-path
```

Run the smoke test to check provisioning and the mount:

```bash
kubectl apply -f k8s/local-path/smoke-test.yaml
kubectl wait --for=condition=Ready pod/local-path-smoke --timeout=120s
kubectl exec local-path-smoke -- cat /data/result
kubectl get pvc,pv -o wide
```

The file should contain `local-path-ok`. The StorageClass retains data, so change only the test PV to `Delete` before cleanup:

```bash
SMOKE_PV=$(kubectl get pvc local-path-smoke -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$SMOKE_PV" --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
kubectl delete -f k8s/local-path/smoke-test.yaml
```

The requested PVC size is Kubernetes metadata, not an enforced directory limit. Local Path Provisioner currently ignores capacity limits. This `hostPath` data shares `EPHEMERAL` with images, logs, kubelet, and containerd, so monitor disk use and node `DiskPressure`:

```bash
talosctl --nodes <worker-ip> usage /var/mnt/local-pvs --humanize --depth 2
kubectl get pvc,pv -A
kubectl describe node <worker-name>
```

References: [Talos local storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage), [StorageClass binding and reclaim policies](https://kubernetes.io/docs/concepts/storage/storage-classes/), [`hostPath` accounting and disk pressure](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath), and [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).

### 3. Place the stateful workloads

`WaitForFirstConsumer` delays PV creation until Kubernetes chooses a node. It does not put PostgreSQL, Elasticsearch, and Neo4j on different workers by itself. Label the chosen workers after they join:

```bash
kubectl label node <postgres-worker> storage-role=postgres
kubectl label node <elastic-worker> storage-role=elastic
kubectl label node <neo4j-worker> storage-role=neo4j
```

Each Helm chart or StatefulSet needs the matching node selector and an explicit `storageClassName`:

```yaml
# PostgreSQL example; use elastic or neo4j on the other workloads.
nodeSelector:
  storage-role: postgres

# In the PVC or volumeClaimTemplate:
storageClassName: local-path
```

Use `nodeSelector` or node affinity instead of `spec.nodeName`. Setting `spec.nodeName` bypasses the scheduler and can leave a `WaitForFirstConsumer` claim pending. Check placement and binding after each deployment:

```bash
kubectl get pods -A -o wide
kubectl get pvc,pv -A -o wide
```

These volumes survive Pod replacement and node reboot, but each one remains tied to the worker that holds its directory. If that worker is off or fails, the database Pod cannot mount the volume elsewhere. It remains unavailable until the original node and its data return. This provides persistence, not replication or high availability. Back up any data that stops being disposable.

References: [assigning Pods to nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/), [local-volume scheduling](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode), and [StatefulSet storage](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-storage).

### 4. Configure a second admin machine

These steps apply to a second laptop or workstation, not a Talos node.

- [ ] Install `talosctl` and `sops`; install `mise` if wanted.
- [ ] Put an age private key on the machine and set its path in `SOPS_AGE_KEY_FILE`. Use the existing key or add the new key's public recipient to `.sops.yaml`.
- [ ] Clone the repository. The working tree should contain encrypted sidecars only.
- [ ] Create a local, gitignored `mise.toml` or export `SOPS_AGE_KEY_FILE`.
- [ ] Run `make decrypt` and confirm that it produces plaintext without a `SOPS_AGE_KEY_FILE is unset` error.
- [ ] With the control plane on, run `talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./secrets/talosconfig version`.
- [ ] Run `talosctl --nodes $CONTROL_PLANE_IP get nodename`, or `health` after kubeconfig exists.
- [ ] Confirm that `git status` does not list `cfg/controlplane.yaml`, `cfg/worker.yaml`, or `secrets/talosconfig`.

If decryption works but `talosctl` fails, sops has the right key and the problem is cluster access: the node may be off, `CONTROL_PLANE_IP` may be wrong, or `talosconfig` may contain stale endpoints. If decryption fails, the age identity does not match `.sops.yaml`.

## Operations

Most `talosctl` commands need `--nodes` or `-n`. An endpoint is the control-plane address that `talosctl` contacts. A node is the machine the request concerns. Do not use `--insecure` after bootstrap.

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
make encrypt                    # plaintext to *.enc.yaml
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

See the [talosctl CLI reference](https://docs.siderolabs.com/talos/v1.13/reference/cli) for the full command list and [Talos for Linux admins](https://docs.siderolabs.com/talos/v1.13/learn-more/talos-for-linux-admins) for familiar Linux equivalents.

## Glossary

**Talos Linux:** A minimal, immutable OS from [Sidero Labs](https://www.siderolabs.com/) built only to run Kubernetes. It has no SSH, shell, or package manager. Nodes are managed through an API.

**Sidero Labs:** The company behind Talos and Omni.

**talosctl:** The Talos API command-line client. It covers the jobs normally handled through SSH, `systemctl`, and `journalctl` on a conventional Linux machine.

**Maintenance mode:** A node that has booted the ISO in memory but has no machine configuration. Its API is unauthenticated, and `apply-config --insecure` claims it. Anyone on the network can do that until a configuration is applied. The ISO does not write to disk before then.

**Machine config:** Declarative YAML applied to a node (`cfg/controlplane.yaml` or `cfg/worker.yaml`). One document defines the OS installation, cluster membership, and Kubernetes role.

**Control plane:** A node running etcd and the Kubernetes control-plane components: the API server, scheduler, and controller manager. Ports 6443 for Kubernetes and 50000 for the Talos API must be reachable. This cluster has one control plane. Talos normally taints control-plane nodes to keep ordinary workloads off them unless `cluster.allowSchedulingOnControlPlanes` is enabled. Check the live taints with `kubectl describe node`.

**Worker:** A node that runs workloads through kubelet and the container runtime. It does not run etcd. It uses the same Talos OS with a different `machine.type`. A control-plane node can run workloads only when its scheduling configuration and taints allow it.

**etcd:** The distributed key-value store Kubernetes uses for cluster state and object specifications. `talosctl bootstrap` initializes it on the first control plane. Kubernetes has no working API until bootstrap succeeds.

**Bootstrap:** The one-time command that starts etcd on one control plane after its machine configuration is applied. Additional control planes join that etcd cluster and are not bootstrapped separately.

**Endpoint and node:** An endpoint is the address `talosctl` contacts, usually a control plane. A node, passed with `-n`, is the machine the request concerns. Endpoints proxy requests to other members, so inspecting a worker does not require changing the endpoint.

**talosconfig:** Client certificates and endpoints for the Talos API, stored here as `./secrets/talosconfig` or normally as `~/.talos/config`. It grants OS and cluster administration through the Talos API, not `kubectl` access. Git holds `secrets/talosconfig.enc.yaml`.

**sops and age:** sops provides key-level YAML encryption and age supplies the recipient identity. YAML keys stay readable while values become `ENC[...]`. `.sops.yaml` contains the age public key; the private key stays on the admin machine at `SOPS_AGE_KEY_FILE`.

**User volume:** Talos-managed local storage mounted at `/var/mnt/<name>`. Depending on `volumeType`, it may be a partition, a whole disk, or a directory backed by `EPHEMERAL`. It is not a Kubernetes PersistentVolume until a Pod mounts it directly through `hostPath` or a provisioner creates PVs beneath it.

**kubeconfig:** Credentials for the Kubernetes API, fetched with `talosctl kubeconfig` after bootstrap. This is a different file and API from `talosconfig`: Kubernetes uses port 6443, while Talos uses port 50000.

**Image Factory:** [factory.talos.dev](https://factory.talos.dev/) builds Talos ISOs and installers. It can include hardware-specific system extensions, such as NIC drivers, if a G5 needs them.

**Omni:** Sidero's hosted or self-hosted control plane for managing Talos machines across sites. This cluster uses `talosctl` directly instead.

**KubePrism:** An on-node proxy that lets kubelets reach the Kubernetes API locally when the external endpoint is unavailable or inconvenient. It becomes more useful with multiple control planes.

## License

Licensed under the [MIT License](LICENSE).

## Acknowledgements

The README structure is adapted from [Awesome Readme Template](https://github.com/Louis3797/awesome-readme-template). Cluster procedures and reference material come from the linked Talos and Kubernetes documentation.
