#!/bin/bash
set -euo pipefail

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

ARCHZFS_KEY=3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

# --- Add archzfs repo (for zfs-dkms + zfs-utils) ---
if grep -q '^\[archzfs\]' /etc/pacman.conf; then
  echo "archzfs repo already in pacman.conf"
else
  echo "Adding archzfs repo to pacman.conf..."
  # Append at end (no need to be before [core] with DKMS)
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

# --- Enable ZFS services ---
echo "Enabling ZFS services..."
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target

echo ""
echo "ZFS setup complete."
echo "DKMS compiled modules for all installed kernels."
echo "Reboot to use ZFS."
