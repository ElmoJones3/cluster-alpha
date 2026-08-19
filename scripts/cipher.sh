#!/usr/bin/env bash
#
# Encrypt and decrypt the managed sops sidecars in this repository.
#
# Plaintext is the working copy and wins whenever it exists:
#
#   plaintext  ciphertext  encrypt             decrypt
#   missing    present     error               create plaintext
#   present    missing     create ciphertext   error
#   present    present     update if changed   keep plaintext
#   missing    missing     error               error
#
# `decrypt --force` is the explicit recovery path for replacing plaintext.
# `--dry-run` performs the same checks and comparisons without changing a
# managed file. Encrypt still works without a private key. Without one, it
# cannot compare randomized ciphertext, so it reports or performs an update.

set -euo pipefail

# Sops otherwise creates fresh plaintext with permissions derived from the
# caller's umask. Secrets staged by this script must start private.
umask 077

launch_dir="$PWD"
root="$(cd "$(dirname "$0")/.." && pwd -P)"

FILES=(
  cfg/controlplane.yaml
  cfg/worker.yaml
  secrets/talosconfig
)

usage() {
  cat <<'EOF'
usage: scripts/cipher.sh <encrypt|decrypt> [--dry-run] [--force] [path...]

  encrypt            write ciphertext from canonical plaintext
  decrypt            create missing plaintext and keep existing plaintext
  decrypt --force    replace existing plaintext from ciphertext
  --dry-run           check and report without changing managed files

Paths must be entries in the script's FILES list. Omit them to process all.
EOF
}

die() {
  echo "cipher: $*" >&2
  exit 1
}

enc_path() {
  local src="$1"
  if [[ "$src" == *.yaml ]]; then
    printf '%s\n' "${src%.yaml}.enc.yaml"
  else
    printf '%s\n' "${src}.enc.yaml"
  fi
}

sops_yaml() {
  sops --input-type yaml --output-type yaml "$@"
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not on PATH"
}

# mise does not expand a quoted ~/ path in an environment value. Relative key
# paths should also keep the meaning they had where the script was invoked,
# before this script changes to the repository root.
resolve_age_key_file() {
  local key_file="${SOPS_AGE_KEY_FILE:-}"

  [[ -n "$key_file" ]] || return 0

  case "$key_file" in
    '~/'*)
      [[ -n "${HOME:-}" ]] || die "HOME is unset; cannot expand SOPS_AGE_KEY_FILE"
      key_file="$HOME/${key_file#\~/}"
      ;;
    /*) ;;
    *) key_file="$launch_dir/$key_file" ;;
  esac

  SOPS_AGE_KEY_FILE="$key_file"
  export SOPS_AGE_KEY_FILE
}

age_key_available() {
  [[ -n "${SOPS_AGE_KEY_FILE:-}" && -f "$SOPS_AGE_KEY_FILE" && -r "$SOPS_AGE_KEY_FILE" ]]
}

need_age_key_file() {
  [[ -n "${SOPS_AGE_KEY_FILE:-}" ]] || \
    die "SOPS_AGE_KEY_FILE is unset (path to the age private key)"
  [[ -f "$SOPS_AGE_KEY_FILE" ]] || \
    die "SOPS_AGE_KEY_FILE is not a file: $SOPS_AGE_KEY_FILE"
  [[ -r "$SOPS_AGE_KEY_FILE" ]] || \
    die "SOPS_AGE_KEY_FILE is not readable: $SOPS_AGE_KEY_FILE"
}

is_managed() {
  local candidate="$1"
  local managed
  for managed in "${FILES[@]}"; do
    [[ "$candidate" == "$managed" ]] && return 0
  done
  return 1
}

validate_targets() {
  local target
  local prior
  local dst

  for target in "${targets[@]}"; do
    is_managed "$target" || die "unmanaged plaintext path: $target"

    if [[ "${#seen_targets[@]}" -gt 0 ]]; then
      for prior in "${seen_targets[@]}"; do
        [[ "$target" != "$prior" ]] || die "duplicate plaintext path: $target"
      done
    fi
    seen_targets+=("$target")

    dst="$(enc_path "$target")"
    if [[ "$mode" == encrypt ]]; then
      [[ -e "$target" ]] || die "missing plaintext: $target"
      [[ ! -L "$target" && -f "$target" && -r "$target" ]] || \
        die "plaintext is not a readable regular file: $target"
      if [[ -e "$dst" || -L "$dst" ]]; then
        [[ ! -L "$dst" && -f "$dst" ]] || \
          die "ciphertext destination is not a regular file: $dst"
      fi
    else
      [[ -e "$dst" ]] || die "missing ciphertext: $dst"
      [[ ! -L "$dst" && -f "$dst" && -r "$dst" ]] || \
        die "ciphertext is not a readable regular file: $dst"
      if [[ -e "$target" || -L "$target" ]]; then
        [[ ! -L "$target" && -f "$target" ]] || \
          die "plaintext destination is not a regular file: $target"
      fi
    fi
  done
}

temp_files=()
new_temp_for() {
  local path="$1"
  local dir="${path%/*}"
  local base="${path##*/}"

  NEW_TEMP="$(mktemp "$dir/.${base}.cipher.XXXXXX")" || \
    die "could not create a temporary file beside $path"
  temp_files+=("$NEW_TEMP")
}

cleanup() {
  local file
  set +e
  if [[ "${#temp_files[@]}" -gt 0 ]]; then
    for file in "${temp_files[@]}"; do
      [[ ! -e "$file" && ! -L "$file" ]] || rm -f "$file"
    done
  fi
}
trap cleanup EXIT

# Return 0 when two ciphertext files decrypt to the same normalized YAML, 1
# when they differ, and 2 when the available key cannot compare them.
ciphertexts_match() {
  local left="$1"
  local right="$2"
  local left_plain
  local right_plain

  new_temp_for "$left"
  left_plain="$NEW_TEMP"
  new_temp_for "$right"
  right_plain="$NEW_TEMP"

  if ! sops_yaml --decrypt --output "$left_plain" "$left" >/dev/null 2>&1; then
    return 2
  fi
  if ! sops_yaml --decrypt --output "$right_plain" "$right" >/dev/null 2>&1; then
    return 2
  fi

  cmp -s "$left_plain" "$right_plain"
}

# Sops rewrites YAML indentation. Normalize local plaintext through the same
# encrypt/decrypt path before deciding whether it matches decrypted content.
plaintext_matches() {
  local plaintext="$1"
  local decrypted="$2"
  local normalized_cipher
  local normalized_plain

  cmp -s "$plaintext" "$decrypted" && return 0

  new_temp_for "$plaintext"
  normalized_cipher="$NEW_TEMP"
  new_temp_for "$plaintext"
  normalized_plain="$NEW_TEMP"

  if ! sops_yaml --encrypt --output "$normalized_cipher" "$plaintext" >/dev/null 2>&1; then
    return 1
  fi
  if ! sops_yaml --decrypt --output "$normalized_plain" "$normalized_cipher" >/dev/null 2>&1; then
    return 1
  fi

  cmp -s "$normalized_plain" "$decrypted"
}

write_stages=()
write_destinations=()
reports=()

record_write() {
  write_stages+=("$1")
  write_destinations+=("$2")
  reports+=("$3")
}

plan_encrypt() {
  local src="$1"
  local dst
  local stage
  local match_status

  dst="$(enc_path "$src")"
  new_temp_for "$dst"
  stage="$NEW_TEMP"
  sops_yaml --encrypt --output "$stage" "$src"
  chmod 0644 "$stage"

  if [[ ! -e "$dst" ]]; then
    if [[ "$dry_run" == true ]]; then
      record_write "$stage" "$dst" "would create ciphertext: $src -> $dst"
    else
      record_write "$stage" "$dst" "encrypted: $src -> $dst"
    fi
    return
  fi

  if age_key_available; then
    if ciphertexts_match "$dst" "$stage"; then
      reports+=("unchanged ciphertext: $dst")
      return
    else
      match_status=$?
      if [[ "$match_status" -eq 2 ]]; then
        reports+=("could not compare ciphertext with the available key: $dst")
      fi
    fi
  else
    reports+=("could not compare ciphertext without SOPS_AGE_KEY_FILE: $dst")
  fi

  if [[ "$dry_run" == true ]]; then
    record_write "$stage" "$dst" "would update ciphertext: $src -> $dst"
  else
    record_write "$stage" "$dst" "encrypted: $src -> $dst"
  fi
}

plan_decrypt() {
  local src="$1"
  local dst
  local stage

  dst="$(enc_path "$src")"
  new_temp_for "$src"
  stage="$NEW_TEMP"
  sops_yaml --decrypt --output "$stage" "$dst"
  chmod 0600 "$stage"

  if [[ ! -e "$src" ]]; then
    if [[ "$dry_run" == true ]]; then
      record_write "$stage" "$src" "would create plaintext: $dst -> $src"
    else
      record_write "$stage" "$src" "decrypted: $dst -> $src"
    fi
    return
  fi

  if plaintext_matches "$src" "$stage"; then
    reports+=("unchanged plaintext: $src")
    return
  fi

  if [[ "$force" == false ]]; then
    reports+=("kept local plaintext: $src differs from $dst")
    return
  fi

  if [[ "$dry_run" == true ]]; then
    record_write "$stage" "$src" "would replace plaintext: $dst -> $src"
  else
    record_write "$stage" "$src" "restored plaintext: $dst -> $src"
  fi
}

backups=()
committed_count=0
commit_active=false

rollback_writes() {
  local index
  local dst
  local backup
  local rollback_failed=0

  index=$((committed_count - 1))
  while [[ "$index" -ge 0 ]]; do
    dst="${write_destinations[$index]}"
    backup="${backups[$index]}"
    if [[ -n "$backup" ]]; then
      mv -f "$backup" "$dst" || rollback_failed=1
    else
      rm -f "$dst" || rollback_failed=1
    fi
    index=$((index - 1))
  done

  [[ "$rollback_failed" -eq 0 ]] || echo "cipher: rollback failed" >&2
}

handle_signal() {
  local exit_code="$1"
  trap - HUP INT TERM
  if [[ "$commit_active" == true && "$committed_count" -gt 0 ]]; then
    rollback_writes
  fi
  exit "$exit_code"
}

trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

commit_writes() {
  local index
  local dst
  local stage

  for ((index = 0; index < ${#write_destinations[@]}; index++)); do
    dst="${write_destinations[$index]}"
    if [[ -e "$dst" ]]; then
      new_temp_for "$dst"
      cp -p "$dst" "$NEW_TEMP"
      backups[$index]="$NEW_TEMP"
    else
      backups[$index]=""
    fi
  done

  commit_active=true
  for ((index = 0; index < ${#write_destinations[@]}; index++)); do
    dst="${write_destinations[$index]}"
    stage="${write_stages[$index]}"
    committed_count=$((index + 1))
    if ! mv -f "$stage" "$dst"; then
      rollback_writes
      commit_active=false
      die "could not replace $dst; restored earlier files"
    fi
  done
  commit_active=false
}

[[ $# -gt 0 ]] || {
  usage >&2
  exit 2
}

mode="$1"
shift

case "$mode" in
  encrypt | decrypt) ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

dry_run=false
force=false
targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --force) force=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        targets+=("$1")
        shift
      done
      break
      ;;
    -*) die "unknown option: $1" ;;
    *) targets+=("$1") ;;
  esac
  shift
done

[[ "$force" == false || "$mode" == decrypt ]] || \
  die "--force is only valid with decrypt"

if [[ "${#targets[@]}" -eq 0 ]]; then
  targets=("${FILES[@]}")
fi

need_command sops
resolve_age_key_file
cd "$root"

if [[ "$mode" == decrypt ]]; then
  need_age_key_file
fi

seen_targets=()
validate_targets

for target in "${targets[@]}"; do
  "plan_$mode" "$target"
done

if [[ "$dry_run" == false && "${#write_destinations[@]}" -gt 0 ]]; then
  commit_writes
fi

if [[ "${#reports[@]}" -gt 0 ]]; then
  for report in "${reports[@]}"; do
    echo "$report"
  done
fi
