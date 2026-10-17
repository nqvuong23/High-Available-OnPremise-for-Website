#!/usr/bin/env bash
# Generate an encrypted vault.yml with random secrets for a fresh lab.
# Usage: bash gen-vault.sh [--force]
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ansible_dir=$(cd "${ANSIBLE_DIR:-$here/../../ansible}" && pwd)
vault_file="$ansible_dir/inventory/group_vars/all/vault.yml"
pass_file=${VAULT_PASS_FILE:-$HOME/.vault_pass.txt}

command -v ansible-vault >/dev/null || { echo "[ERROR] ansible-vault not found, activate the venv first" >&2; exit 1; }
command -v openssl >/dev/null || { echo "[ERROR] openssl not found" >&2; exit 1; }

if [[ -e $vault_file && ${1:-} != --force ]]; then
    echo "[ERROR] $vault_file exists; rerun command with parameter [--force] to replace every secret" >&2
    exit 1
fi

# alphanumeric only: these values land inside PHP and SQL string literals
rand() { openssl rand -base64 $(( $1 * 2 )) | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

if [[ ! -s $pass_file ]]; then
    ( umask 077; rand 32 > "$pass_file" )
    echo "[INFO] created vault password file $pass_file"
fi
chmod 600 "$pass_file"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<EOF
---
vault_mysql_repl_password: $(rand 24)
vault_mysql_wp_password: $(rand 24)
vault_mysql_ops_password: $(rand 24)
vault_mysql_chk_password: $(rand 24)
vault_haproxy_stats_password: $(rand 16)
vault_keepalived_auth_pass: $(rand 8)
vault_wordpress_admin_password: $(rand 16)
vault_wordpress_salts:
  auth_key: $(rand 64)
  secure_auth_key: $(rand 64)
  logged_in_key: $(rand 64)
  nonce_key: $(rand 64)
  auth_salt: $(rand 64)
  secure_auth_salt: $(rand 64)
  logged_in_salt: $(rand 64)
  nonce_salt: $(rand 64)
EOF

ansible-vault encrypt --vault-password-file "$pass_file" --encrypt-vault-id default --output "$vault_file" "$tmp" >/dev/null
echo "[OK] wrote encrypted $vault_file"
echo "[INFO] read a value with: ansible-vault view $vault_file"
