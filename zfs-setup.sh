#!/bin/bash
set -euo pipefail

# ZFS DKMS installation for Arch Linux
# Services and configuration are handled by ansible zfs role

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

ARCHZFS_KEY=3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

# --- Add archzfs repo ---
if grep -q '^\[archzfs\]' /etc/pacman.conf; then
  echo "archzfs repo already in pacman.conf"
else
  echo "Adding archzfs repo to pacman.conf..."
  cat >>/etc/pacman.conf <<REPO

[archzfs]
Server = https://github.com/archzfs/archzfs/releases/download/experimental
REPO
fi

# --- Import archzfs key ---
echo "Importing archzfs key..."
pacman-key --recv-keys "$ARCHZFS_KEY"
pacman-key --lsign-key "$ARCHZFS_KEY"
pacman -Sy

# --- Install ZFS DKMS ---
echo "Installing ZFS DKMS (this will compile modules)..."
pacman -S --noconfirm --needed zfs-dkms zfs-utils

echo ""
echo "ZFS DKMS installed."
echo "Run ansible zfs role to configure services and datasets."
