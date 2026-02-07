# List available recipes
default:
    @just --list

vm := "arch-test"
iso := justfile_directory() / "archlinux-2026.02.01-x86_64.iso"
ansible_dir := justfile_directory() / "ansible"
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no"
remote_dir := "/root/arch"

# Get VM IP
[private]
vm-ip:
    @incus list {{ vm }} -f json | jq -r '[.[0].state.network.eth0.addresses[] | select(.family=="inet").address] | first'

# Create VM from ISO and open VGA console
spinup:
    incus create {{ vm }} --vm --empty \
      -c limits.cpu=4 \
      -c limits.memory=8GiB \
      -c security.secureboot=false \
      -d root,size=60GiB
    incus config device add {{ vm }} iso disk \
      source="{{ iso }}" \
      boot.priority=10
    incus start {{ vm }}
    @echo "Waiting for VM to boot..."
    @sleep 3
    incus console {{ vm }} --type=vga

# Open console
console:
    incus console {{ vm }} --type=vga

# Sync install script + rootfs overlay to the VM
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(just vm-ip)
    rsync -avz --delete \
      -e "ssh {{ ssh_opts }}" \
      --exclude='justfile' \
      --exclude='*.iso' \
      --exclude='.git' \
      --exclude='ansible/' \
      "{{ justfile_directory() }}/" \
      "root@${IP}:{{ remote_dir }}/"
    echo "Synced to root@${IP}:{{ remote_dir }}/"

# SSH into the VM as root
ssh:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(just vm-ip)
    ssh {{ ssh_opts }} "root@${IP}"

# Sync + run the install script in the VM
install *args:
    #!/usr/bin/env bash
    set -euo pipefail
    just sync
    IP=$(just vm-ip)
    ssh {{ ssh_opts }} "root@${IP}" "{{ remote_dir }}/arch-install.sh {{ args }}"

# Run ansible from the host against the VM (pass hostname as first arg)
ansible hostname *args:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(just vm-ip)
    INV=$(mktemp)
    trap "rm -f ${INV}" EXIT
    echo "{{ hostname }} ansible_host=${IP}" > "${INV}"
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_SSH_ARGS="-o PubkeyAuthentication=no" \
    "{{ ansible_dir }}/run-playbook.sh" \
      -i "${INV}" \
      -u gorschu \
      --ask-pass \
      {{ args }}

# Destroy the VM
destroy:
    incus delete {{ vm }} --force
