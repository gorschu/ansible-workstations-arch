#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Installing Ansible collections and roles..."
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml

# Use op whoami: fails cleanly when not signed in, unlike op account list which
# returns exit 0 when empty and can block with interactive setup prompts.
if command -v op &>/dev/null && timeout 5 op whoami </dev/null &>/dev/null; then
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
