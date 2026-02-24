#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Installing Ansible collections and roles..."
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml

# Check if op is available and has an active session.
# Try whoami first; if that fails, attempt a non-interactive signin via app
# integration (stdin closed so it can't block), then verify with whoami again.
op_ready() {
  command -v op &>/dev/null || return 1
  timeout 5 op whoami </dev/null &>/dev/null && return 0
  timeout 5 op signin </dev/null &>/dev/null || return 1
  timeout 5 op whoami </dev/null &>/dev/null
}
if op_ready; then
  echo "==> Using 1Password for vault password"
  ansible-playbook \
    --vault-password-file <(op read "op://Ansible/vault-workstations/password") \
    --ask-become-pass \
    "$@" \
    local.yml
else
  echo "==> 1Password CLI not available, will prompt for vault password"
  ansible-playbook \
    --ask-vault-pass \
    --ask-become-pass \
    "$@" \
    local.yml
fi
