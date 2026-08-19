#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
subject="$project_root/scripts/cipher.sh"

for command_name in sops age-keygen; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing test dependency: $command_name" >&2
    exit 1
  }
done

test_root="$(mktemp -d "${TMPDIR:-/tmp}/cipher-test.XXXXXX")"
fixture="$test_root/repo"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file $1"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]] || fail "output did not contain: $expected"
}

file_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

file_inode() {
  if stat -f '%i' "$1" >/dev/null 2>&1; then
    stat -f '%i' "$1"
  else
    stat -c '%i' "$1"
  fi
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

run_cipher() {
  HOME="$fixture/home" SOPS_AGE_KEY_FILE='~/key.txt' \
    "$fixture/scripts/cipher.sh" "$@"
}

run_cipher_without_key() {
  env -u SOPS_AGE_KEY_FILE HOME="$fixture/home" \
    "$fixture/scripts/cipher.sh" "$@"
}

mkdir -p "$fixture/scripts" "$fixture/cfg" "$fixture/secrets" "$fixture/home"
cp "$subject" "$fixture/scripts/cipher.sh"
chmod +x "$fixture/scripts/cipher.sh"
age-keygen -o "$fixture/home/key.txt" >/dev/null 2>&1
recipient="$(age-keygen -y "$fixture/home/key.txt")"

cat >"$fixture/.sops.yaml" <<EOF
creation_rules:
  - path_regex: .*\.secret\.yaml$
    age: $recipient
EOF

cat >"$fixture/cfg/controlplane.secret.yaml" <<'EOF'
machine:
  token: control-plane-token
EOF

cat >"$fixture/cfg/worker.secret.yaml" <<'EOF'
machine:
  token: worker-token
EOF

cat >"$fixture/secrets/talosconfig.secret.yaml" <<'EOF'
context: alpha
endpoints:
  - 10.0.0.10
EOF

control_plain_hash="$(file_hash "$fixture/cfg/controlplane.secret.yaml")"
if run_cipher decrypt cfg/controlplane.secret.yaml >/dev/null 2>&1; then
  fail "decrypt accepted missing ciphertext"
fi
[[ "$(file_hash "$fixture/cfg/controlplane.secret.yaml")" == "$control_plain_hash" ]] || \
  fail "failed decrypt changed plaintext"

if "$fixture/scripts/cipher.sh" >/dev/null 2>&1; then
  fail "missing mode was accepted"
fi

cat >"$fixture/cfg/extra.secret.yaml" <<'EOF'
secret: stray
EOF
if run_cipher encrypt cfg/extra.secret.yaml >/dev/null 2>&1; then
  fail "unmanaged target was accepted"
fi
assert_no_file "$fixture/cfg/extra.secret.sops.yaml"

run_cipher_without_key encrypt >/dev/null
for encrypted in \
  "$fixture/cfg/controlplane.secret.sops.yaml" \
  "$fixture/cfg/worker.secret.sops.yaml" \
  "$fixture/secrets/talosconfig.secret.sops.yaml"; do
  assert_file "$encrypted"
  [[ "$(file_mode "$encrypted")" == 644 ]] || fail "wrong ciphertext mode for $encrypted"
done

control_cipher_hash="$(file_hash "$fixture/cfg/controlplane.secret.sops.yaml")"
worker_cipher_hash="$(file_hash "$fixture/cfg/worker.secret.sops.yaml")"
talos_cipher_hash="$(file_hash "$fixture/secrets/talosconfig.secret.sops.yaml")"
run_cipher encrypt >/dev/null
[[ "$(file_hash "$fixture/cfg/controlplane.secret.sops.yaml")" == "$control_cipher_hash" ]] || \
  fail "unchanged control-plane ciphertext was rewritten"
[[ "$(file_hash "$fixture/cfg/worker.secret.sops.yaml")" == "$worker_cipher_hash" ]] || \
  fail "unchanged worker ciphertext was rewritten"
[[ "$(file_hash "$fixture/secrets/talosconfig.secret.sops.yaml")" == "$talos_cipher_hash" ]] || \
  fail "unchanged talosconfig ciphertext was rewritten"

printf '\nlocal_change: true\n' >>"$fixture/cfg/controlplane.secret.yaml"
dry_output="$(run_cipher encrypt --dry-run cfg/controlplane.secret.yaml)"
assert_contains "$dry_output" "would update ciphertext"
[[ "$(file_hash "$fixture/cfg/controlplane.secret.sops.yaml")" == "$control_cipher_hash" ]] || \
  fail "encrypt dry-run changed ciphertext"

cp "$fixture/cfg/worker.secret.yaml" "$test_root/worker.secret.yaml"
rm "$fixture/cfg/worker.secret.yaml"
if run_cipher encrypt >/dev/null 2>&1; then
  fail "encrypt accepted a missing plaintext file"
fi
[[ "$(file_hash "$fixture/cfg/controlplane.secret.sops.yaml")" == "$control_cipher_hash" ]] || \
  fail "encrypt changed an earlier file before preflight failed"
cp "$test_root/worker.secret.yaml" "$fixture/cfg/worker.secret.yaml"

run_cipher encrypt cfg/controlplane.secret.yaml >/dev/null
[[ "$(file_hash "$fixture/cfg/controlplane.secret.sops.yaml")" != "$control_cipher_hash" ]] || \
  fail "changed plaintext did not update ciphertext"

rm "$fixture/cfg/controlplane.secret.yaml" "$fixture/cfg/worker.secret.yaml" "$fixture/secrets/talosconfig.secret.yaml"
dry_output="$(run_cipher decrypt --dry-run)"
assert_contains "$dry_output" "would create plaintext"
assert_no_file "$fixture/cfg/controlplane.secret.yaml"
assert_no_file "$fixture/cfg/worker.secret.yaml"
assert_no_file "$fixture/secrets/talosconfig.secret.yaml"

run_cipher decrypt >/dev/null
for plaintext in \
  "$fixture/cfg/controlplane.secret.yaml" \
  "$fixture/cfg/worker.secret.yaml" \
  "$fixture/secrets/talosconfig.secret.yaml"; do
  assert_file "$plaintext"
  [[ "$(file_mode "$plaintext")" == 600 ]] || fail "wrong plaintext mode for $plaintext"
done

worker_inode="$(file_inode "$fixture/cfg/worker.secret.yaml")"
run_cipher decrypt >/dev/null
[[ "$(file_inode "$fixture/cfg/worker.secret.yaml")" == "$worker_inode" ]] || \
  fail "unchanged plaintext was replaced"

printf '\nlocal_only: true\n' >>"$fixture/cfg/worker.secret.yaml"
worker_plain_hash="$(file_hash "$fixture/cfg/worker.secret.yaml")"
decrypt_output="$(run_cipher decrypt cfg/worker.secret.yaml)"
assert_contains "$decrypt_output" "kept local plaintext"
[[ "$(file_hash "$fixture/cfg/worker.secret.yaml")" == "$worker_plain_hash" ]] || \
  fail "decrypt overwrote canonical local plaintext"

force_dry_output="$(run_cipher decrypt --force --dry-run cfg/worker.secret.yaml)"
assert_contains "$force_dry_output" "would replace plaintext"
[[ "$(file_hash "$fixture/cfg/worker.secret.yaml")" == "$worker_plain_hash" ]] || \
  fail "forced decrypt dry-run changed plaintext"

run_cipher decrypt --force cfg/worker.secret.yaml >/dev/null
if grep -q '^local_only:' "$fixture/cfg/worker.secret.yaml"; then
  fail "forced decrypt did not restore ciphertext content"
fi
[[ "$(file_mode "$fixture/cfg/worker.secret.yaml")" == 600 ]] || \
  fail "forced decrypt changed plaintext permissions"

cp "$fixture/cfg/worker.secret.sops.yaml" "$test_root/worker.secret.sops.yaml"
printf 'not: valid: yaml\n' >"$fixture/cfg/worker.secret.sops.yaml"
rm "$fixture/cfg/controlplane.secret.yaml" "$fixture/cfg/worker.secret.yaml" "$fixture/secrets/talosconfig.secret.yaml"
if run_cipher decrypt >/dev/null 2>&1; then
  fail "decrypt accepted corrupt ciphertext"
fi
assert_no_file "$fixture/cfg/controlplane.secret.yaml"
assert_no_file "$fixture/cfg/worker.secret.yaml"
assert_no_file "$fixture/secrets/talosconfig.secret.yaml"
mv "$test_root/worker.secret.sops.yaml" "$fixture/cfg/worker.secret.sops.yaml"

echo "ok: cipher state transitions"
