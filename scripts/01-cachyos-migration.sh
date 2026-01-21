#!/usr/bin/env bash
# First boot script: Migrate to CachyOS repositories and kernel
# Run as root after fresh archinstall
#
# Uses official CachyOS repo installer:
# https://wiki.cachyos.org/features/optimized_repos/

set -euo pipefail

echo "==> CachyOS Migration Script"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Backup original pacman.conf
if [[ ! -f /etc/pacman.conf.archinstall ]]; then
  cp /etc/pacman.conf /etc/pacman.conf.archinstall
  echo "Backed up pacman.conf to pacman.conf.archinstall"
fi

echo ""
echo "==> Downloading official CachyOS repository installer..."
cd /tmp
curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo

echo ""
echo "==> Running CachyOS repository installer..."
echo "(This auto-detects your CPU and installs optimized repos)"
./cachyos-repo.sh

echo ""
echo "==> Refreshing package database..."
pacman -Sy

echo ""
echo "==> Installing CachyOS ZFS kernels (main + LTS fallback)..."
pacman -S --noconfirm linux-cachyos-zfs linux-cachyos-headers linux-cachyos-lts-zfs linux-cachyos-lts-headers

# Cleanup
rm -rf /tmp/cachyos-repo /tmp/cachyos-repo.tar.xz

echo ""
echo "==> Migration complete!"
echo ""
echo "Next steps:"
echo "1. Run: ansible-playbook local.yml -t base,system -K <host>"
echo "   (configures UKI preset and rebuilds initramfs)"
echo "2. Reboot into CachyOS kernel"
echo "3. Run: scripts/02-zfs-setup.sh"
echo "4. Run: ./run-playbook.sh (full playbook)"
