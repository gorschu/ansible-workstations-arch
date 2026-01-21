#!/usr/bin/env bash
# ZFS setup script
# Usage: sudo ./02-zfs-setup.sh /dev/disk/by-id/<disk-id>
#
# Creates ZFS partition, pool, and /home dataset on the specified disk.

set -euo pipefail

# Pool name
POOL_NAME="tank"

# Check arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /dev/disk/by-id/<disk-id>"
  echo "Example: $0 /dev/disk/by-id/scsi-35000c500a1b2c3d4"
  echo ""
  echo "Available disks:"
  for disk in /dev/disk/by-id/*; do
    name=$(basename "$disk")
    [[ $name == dm-* ]] && continue
    [[ $name == *-part[0-9]* ]] && continue
    echo "$name"
  done
  exit 1
fi

DISK="$1"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Validate by-id path
if [[ ! "$DISK" =~ ^/dev/disk/by-id/ ]]; then
  echo "Error: Disk must be a /dev/disk/by-id/ path"
  echo "Example: /dev/disk/by-id/scsi-35000c500a1b2c3d4"
  exit 1
fi

# Check if disk exists
if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK does not exist or is not a block device"
  exit 1
fi

echo "==> ZFS Setup Script"
echo "Using disk: $DISK"
echo ""

# Install required packages
echo "==> Installing required packages..."
pacman -S --noconfirm --needed zfs-utils rsync

# Load ZFS module if needed
if ! lsmod | grep -q "^zfs"; then
  echo "Loading ZFS kernel module..."
  modprobe zfs
fi

# Show current partition layout
echo ""
echo "Current partition layout:"
sgdisk -p "$DISK"
echo ""

# Partition path uses -part suffix for by-id
ZFS_PART="${DISK}-part9"

# Check if partition 9 already exists
if [[ -b "$ZFS_PART" ]]; then
  echo "Partition 9 already exists: ${ZFS_PART}"
else
  echo "==> Creating ZFS partition (partition 9)..."
  sgdisk -n 9:0:0 -t 9:BF01 -c 9:"zfs-data" "$DISK"
  partprobe "$(readlink -f "$DISK")"
  sleep 2
  echo "Created: ${ZFS_PART}"
fi

echo ""

# Generate ZFS encryption key
ZFS_KEYFILE="/etc/zfs/zpool.key"
if [[ ! -f "$ZFS_KEYFILE" ]]; then
  echo "==> Generating ZFS encryption key..."
  mkdir -p /etc/zfs
  dd if=/dev/urandom of="$ZFS_KEYFILE" bs=32 count=1 2>/dev/null
  chmod 600 "$ZFS_KEYFILE"
  echo "Key created: ${ZFS_KEYFILE}"
else
  echo "ZFS key already exists: ${ZFS_KEYFILE}"
fi

echo ""

# Check if pool already exists
if zpool list "$POOL_NAME" &>/dev/null; then
  echo "Pool '${POOL_NAME}' already exists. Skipping pool creation."
else
  echo "==> Creating encrypted ZFS pool '${POOL_NAME}'..."

  # Verify partition symlink exists (should be created by udev after partprobe)
  if [[ ! -b "$ZFS_PART" ]]; then
    echo "Waiting for partition symlink..."
    for _ in {1..10}; do
      sleep 1
      [[ -b "$ZFS_PART" ]] && break
    done
    if [[ ! -b "$ZFS_PART" ]]; then
      echo "Error: Partition symlink ${ZFS_PART} not found after 10 seconds"
      exit 1
    fi
  fi

  # Use the by-id path directly (already validated as input)
  ZFS_DEVICE="$ZFS_PART"
  echo "Using device: ${ZFS_DEVICE}"

  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -O compression=zstd \
    -O encryption=aes-256-gcm \
    -O keyformat=raw \
    -O keylocation="file://${ZFS_KEYFILE}" \
    "$POOL_NAME" "$ZFS_DEVICE"

  echo "Pool created successfully"
fi

echo ""

# Create home dataset
DATASET_HOME="${POOL_NAME}/home"
if zfs list "$DATASET_HOME" &>/dev/null; then
  echo "Dataset '${DATASET_HOME}' already exists."
else
  echo "==> Creating home dataset..."
  zfs create -o mountpoint=/home -o canmount=off "$DATASET_HOME"
  echo "Dataset created: ${DATASET_HOME}"
fi

echo ""

# Check if we need to migrate existing /home
NEEDS_MIGRATION=false
if [[ -d /home ]] && [[ ! -d /home.old ]]; then
  if [[ -n "$(ls -A /home 2>/dev/null)" ]]; then
    CURRENT_HOME_FS=$(findmnt -no FSTYPE /home 2>/dev/null || echo "")
    if [[ "$CURRENT_HOME_FS" != "zfs" ]]; then
      NEEDS_MIGRATION=true
    fi
  fi
fi

if [[ "$NEEDS_MIGRATION" == "true" ]]; then
  echo "==> Migrating existing /home to ZFS..."
  mv /home /home.old
  mkdir /home
  zfs set canmount=on "$DATASET_HOME"
  zfs mount "$DATASET_HOME"
  echo "Copying data (this may take a while)..."
  rsync -avPX /home.old/ /home/
  echo "Migration complete. Old home preserved at /home.old"
else
  echo "==> Enabling ZFS home dataset..."
  zfs set canmount=on "$DATASET_HOME"
  if ! zfs get -H mounted "$DATASET_HOME" | grep -q "yes"; then
    zfs mount "$DATASET_HOME"
  fi
  echo "ZFS /home is ready"
fi

echo ""

# Enable ZFS services
echo "==> Enabling ZFS services..."

# Deploy zfs-load-key service from ansible role
REPO_ROOT="$(cd "$(dirname "$0")/.." && git rev-parse --show-toplevel)"
cp "${REPO_ROOT}/roles/zfs/files/zfs-load-key.service" /etc/systemd/system/
chmod 644 /etc/systemd/system/zfs-load-key.service

systemctl daemon-reload
systemctl enable zfs-import-cache.service
systemctl enable zfs-load-key.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target
systemctl enable zfs.target
systemctl enable zfs-zed.service

# Generate zpool cache
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

echo ""
echo "==> ZFS setup complete!"
echo ""
zpool status "$POOL_NAME"
echo ""
zfs list -r "$POOL_NAME"
echo ""
echo "WARNING: Back up ${ZFS_KEYFILE} to a secure location!"
echo "         Without this key, your ZFS data is unrecoverable."
echo ""
echo "Next steps:"
if [[ -d /home.old ]]; then
  echo "1. Verify data in /home"
  echo "2. Remove /home.old if everything looks good"
  echo "3. Run: ansible-playbook bootstrap.yml -K"
  echo "4. Sign into 1Password"
  echo "5. Run: ./run-playbook.sh"
  echo "6. Run chezmoi to apply dotfiles"
else
  echo "1. Run: ansible-playbook bootstrap.yml -K"
  echo "2. Sign into 1Password"
  echo "3. Run: ./run-playbook.sh"
  echo "4. Run chezmoi to apply dotfiles"
fi
