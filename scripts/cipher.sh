#!/usr/bin/env bash
#
# cipher.sh — sops/age sidecar encrypt and decrypt for this Talos repo.
#
# Called from the Makefile:
#   make encrypt    →  ./scripts/cipher.sh encrypt
#   make decrypt    →  ./scripts/cipher.sh decrypt
#
# You can also pass a subset of plaintext paths:
#   ./scripts/cipher.sh encrypt cfg/worker.yaml
#   ./scripts/cipher.sh decrypt secrets/talosconfig
#
# =============================================================================
# INTENDED WORKFLOW
# =============================================================================
#
# Two copies of every secret, two jobs:
#
#   cfg/controlplane.yaml      plaintext. talosctl reads this. never committed.
#   cfg/controlplane.enc.yaml  sops YAML. git sees this. humans do not edit it.
#
# Same pair for cfg/worker.yaml and secrets/talosconfig
# (talosconfig has no .yaml suffix; the sidecar is still talosconfig.enc.yaml).
#
# Day to day:
#   1. Clone the repo. Working tree has *.enc.yaml only, under cfg/ and secrets/.
#   2. Point SOPS_AGE_KEY_FILE at the age private key on THIS machine.
#      The key does not live in the repo. The public half lives in .sops.yaml.
#   3. make decrypt
#      Writes plaintext next to the sidecars. .gitignore keeps those out of git.
#   4. talosctl uses the plaintext paths (see mise.toml TALOSCONFIG, Makefile,
#      scripts/workers.sh). No sops wrapper around dashboard or logs.
#   5. Edit the plaintext in a normal editor.
#   6. make encrypt
#      Rewrites the *.enc.yaml sidecars from the plaintext. Commit those.
#
# Encrypt does not need the private key. Age encrypts to the recipient listed
# in .sops.yaml. Decrypt does need SOPS_AGE_KEY_FILE; without it this script
# exits before touching anything.
#
# A box with no private key can still encrypt (if it somehow has plaintext)
# and can still *see* ciphertext in git. It cannot produce plaintext, so it
# cannot talk to the cluster. That is the point.
#
# =============================================================================
# ASSUMPTIONS
# =============================================================================
#
# - You are in a checkout of this repo. The script cd's to the repo root
#   (parent of scripts/) so .sops.yaml is found and paths in FILES are correct.
#
# - sops is on PATH. Recipients are whatever .sops.yaml says for paths matching
#   ^(cfg|secrets)/ — today one age public key. Add recipients there, not here.
#
# - SOPS_AGE_KEY_FILE is a path to a file, not the key material itself.
#   sops also understands SOPS_AGE_KEY (the key inline). We do not use that.
#   We fail if the path is unset or not a file. We do not invent a default path.
#
# - FILES is the allowlist of plaintext that has a sidecar. New secret? Append
#   the plaintext path here, make encrypt, confirm .gitignore still ignores
#   the plaintext and still un-ignores *.enc.yaml. Do not glob the trees;
#   a stray file in cfg/ should not silently become a committed secret.
#
# - Naming rule (enc_path):
#     foo.yaml  →  foo.enc.yaml
#     foo       →  foo.enc.yaml
#   The committed name is always *.enc.yaml so .gitignore can be one pattern.
#   Decrypt writes back to the plaintext name in FILES, not to a third path.
#
# - sops is told --input-type yaml --output-type yaml even when the file has
#   no .yaml suffix (secrets/talosconfig). Without that, sops treats it as
#   binary and you get one blob instead of key-level ENC[...] values.
#
# - Encrypt overwrites an existing sidecar. Decrypt overwrites existing
#   plaintext. No backup, no prompt. Ciphertext in git is the recovery copy.
#
# - This script does not git add, commit, or run a pre-commit hook. Make
#   encrypt then you commit the sidecars. Make decrypt never produces
#   something you should commit.
#
# - First encrypt of Talos-generated YAML will strip comments and reshuffle
#   formatting. sops's YAML emitter does that. After that you edit plaintext;
#   the sidecar is a derivative, not a document.
#
# =============================================================================
# HELPERS (each does one thing; main is the loop at the bottom)
# =============================================================================

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Plaintext paths talosctl / humans edit. Sidecar name comes from enc_path.
# Order does not matter. Keep this list short and explicit.
FILES=(
  cfg/controlplane.yaml
  cfg/worker.yaml
  secrets/talosconfig
)

# Map a plaintext path to its committed sidecar.
# controlplane.yaml → controlplane.enc.yaml
# talosconfig       → talosconfig.enc.yaml
enc_path() {
  local src="$1"
  if [[ "$src" == *.yaml ]]; then
    printf '%s\n' "${src%.yaml}.enc.yaml"
  else
    printf '%s\n' "${src}.enc.yaml"
  fi
}

# Every sops invocation in this file goes through here so the yaml type flags
# cannot drift between encrypt and decrypt.
sops_yaml() {
  sops --input-type yaml --output-type yaml "$@"
}

need_sops() {
  command -v sops >/dev/null || {
    echo "sops not on PATH" >&2
    exit 1
  }
}

# Decrypt-only. Encrypt uses .sops.yaml recipients and must work without this.
need_age_key_file() {
  if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
    echo "SOPS_AGE_KEY_FILE is unset (path to the age private key)" >&2
    exit 1
  fi
  if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
    echo "SOPS_AGE_KEY_FILE is not a file: $SOPS_AGE_KEY_FILE" >&2
    exit 1
  fi
}

# One pair, one direction. Missing plaintext is a hard error (nothing to encrypt).
encrypt_one() {
  local src="$1"
  local dst
  dst="$(enc_path "$src")"
  if [[ ! -f "$src" ]]; then
    echo "missing plaintext: $src" >&2
    exit 1
  fi
  echo "encrypt $src → $dst"
  sops_yaml --encrypt --output "$dst" "$src"
}

# Inverse. Argument is still the plaintext path from FILES; we derive the sidecar.
# Missing sidecar is a hard error (clone without ciphertext, or a new FILE
# that was never encrypted).
decrypt_one() {
  local src="$1"
  local dst
  dst="$(enc_path "$src")"
  if [[ ! -f "$dst" ]]; then
    echo "missing ciphertext: $dst" >&2
    exit 1
  fi
  echo "decrypt $dst → $src"
  sops_yaml --decrypt --output "$src" "$dst"
}

# =============================================================================
# MAIN
# =============================================================================
#
# argv[1] is the verb (required from Make; defaults to encrypt if you run
# the script with no args). Remaining argv are optional plaintext paths;
# omitted means all of FILES.

mode="${1:-encrypt}"
shift || true

case "$mode" in
  encrypt | decrypt) ;;
  -h | --help)
    sed -n '2,80p' "$0"
    exit 0
    ;;
  *)
    echo "usage: $0 [encrypt|decrypt] [path...]" >&2
    exit 1
    ;;
esac

need_sops
[[ "$mode" == decrypt ]] && need_age_key_file

if [[ $# -gt 0 ]]; then
  targets=("$@")
else
  targets=("${FILES[@]}")
fi

# Indirect call: encrypt → encrypt_one, decrypt → decrypt_one.
# A new verb needs a matching *_one function; do not add a third direction
# as a flag on these two.
for f in "${targets[@]}"; do
  "${mode}_one" "$f"
done
