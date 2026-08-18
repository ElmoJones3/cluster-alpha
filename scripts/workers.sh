#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${WORKER_IP:-}" ]; then
  echo "WORKER_IP is unset (space-separated IPs in mise.toml)" >&2
  exit 1
fi

# mise string or bash array both work.
read -r -a workers <<< "${WORKER_IP[*]}"

for ip in "${workers[@]}"; do
  echo "Applying config to worker node: $ip"
  talosctl apply-config --insecure --nodes "$ip" --file "$root/cfg/worker.yaml"
done
