# VM testing recipes (libvirt/virt-install)
# Requires: libvirt, virt-install, virt-viewer, rsync
# Usage: just spinup → just install <hostname> <disk> → just vm-ansible <hostname>

vm         := "arch-test"
iso        := justfile_directory() / "archlinux-2026.02.01-x86_64.iso"
ssh_opts   := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no"
remote_dir := "/root/arch"

[private]
vm-ip:
    @virsh domifaddr {{ vm }} --source leases | awk '/ipv4/ {split($4,a,"/"); print a[1]; exit}'

[group('test')]
spinup:
    virt-install \
      --name {{ vm }} \
      --memory 8192 \
      --vcpus 4 \
      --disk size=60,format=qcow2 \
      --cdrom "{{ iso }}" \
      --os-variant archlinux \
      --boot uefi \
      --graphics spice \
      --noautoconsole
    @echo "VM created — run 'just console' to open the graphical console"

[group('test')]
console:
    virt-viewer {{ vm }}

[group('test')]
ssh:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(just vm-ip)
    ssh {{ ssh_opts }} "root@${IP}"

[group('test')]
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(just vm-ip)
    rsync -avz --delete \
      -e "ssh {{ ssh_opts }}" \
      --exclude='justfile' \
      --exclude='test.just' \
      --exclude='*.iso' \
      --exclude='.git' \
      --exclude='ansible/' \
      "{{ justfile_directory() }}/" \
      "root@${IP}:{{ remote_dir }}/"

[group('test')]
install *args:
    #!/usr/bin/env bash
    set -euo pipefail
    just sync
    IP=$(just vm-ip)
    ssh {{ ssh_opts }} "root@${IP}" "{{ remote_dir }}/arch-install.sh {{ args }}"

[group('test')]
vm-ansible hostname *args:
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

[group('test')]
destroy:
    #!/usr/bin/env bash
    virsh destroy {{ vm }} 2>/dev/null || true
    virsh undefine {{ vm }} --nvram --remove-all-storage
