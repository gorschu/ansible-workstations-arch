#!/bin/bash
set -euo pipefail

# ZFS pool creation for Arch Linux
# Run after zfs-setup.sh, before ansible zfs role

POOL_NAME="tank"

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

# --- Ensure gum is available ---
if ! command -v gum &>/dev/null; then
  echo "Installing gum..."
  pacman -S --needed --noconfirm gum
fi

# --- Build disk list ---
disks=()
for disk in /dev/disk/by-id/*; do
  name=$(basename "$disk")
  [[ $name == dm-* ]] && continue
  [[ $name == *-part[0-9]* ]] && continue
  [[ $name == lvm-* ]] && continue
  [[ $name == wwn-* ]] && continue
  disks+=("$disk")
done

if [[ ${#disks[@]} -eq 0 ]]; then
  echo "Error: No disks found in /dev/disk/by-id/"
  exit 1
fi

# --- Disk selection ---
echo "Select disk for ZFS pool:"
DISK=$(gum choose "${disks[@]}")

if [[ -z "$DISK" ]]; then
  echo "No disk selected."
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK does not exist"
  exit 1
fi

# --- Check ZFS is available ---
if ! command -v zpool &>/dev/null; then
  echo "Error: zpool not found. Run zfs-setup.sh first."
  exit 1
fi

# --- Load ZFS module if needed ---
if ! lsmod | grep -q "^zfs"; then
  echo "Loading ZFS module..."
  modprobe zfs
fi

echo "==> ZFS Pool Creation"
echo "Disk: $DISK"
echo "Pool: $POOL_NAME"
echo ""

# --- Show current layout ---
echo "Current partition layout:"
sgdisk -p "$DISK"
echo ""

# --- Partition ---
ZFS_PART="${DISK}-part9"

if [[ -b "$ZFS_PART" ]]; then
  echo "Partition 9 already exists: ${ZFS_PART}"
else
  if ! gum confirm "Create partition 9 on ${DISK}?"; then
    echo "Aborted."
    exit 1
  fi
  echo "Creating ZFS partition (partition 9)..."
  sgdisk -n 9:0:0 -t 9:BF01 -c 9:"zfs-data" "$DISK"
  partprobe "$(readlink -f "$DISK")"
  sleep 2
  echo "Created: ${ZFS_PART}"
fi

# --- Encryption key ---
ZFS_KEYFILE="/etc/zfs/zpool.key"

if [[ ! -f "$ZFS_KEYFILE" ]]; then
  echo "Generating ZFS encryption key..."
  mkdir -p /etc/zfs
  openssl rand -hex 32 > "$ZFS_KEYFILE"
  chmod 600 "$ZFS_KEYFILE"
  echo "Key created: ${ZFS_KEYFILE}"
else
  echo "Key already exists: ${ZFS_KEYFILE}"
fi

# --- Create pool ---
if zpool list "$POOL_NAME" &>/dev/null; then
  echo "Pool '${POOL_NAME}' already exists."
else
  echo ""
  if ! gum confirm "Create encrypted pool '${POOL_NAME}' on ${DISK}-part9?"; then
    echo "Aborted."
    exit 1
  fi
  echo "Creating encrypted ZFS pool '${POOL_NAME}'..."

  # Wait for partition if needed
  if [[ ! -b "$ZFS_PART" ]]; then
    echo "Waiting for partition..."
    for _ in {1..10}; do
      sleep 1
      [[ -b "$ZFS_PART" ]] && break
    done
    if [[ ! -b "$ZFS_PART" ]]; then
      echo "Error: ${ZFS_PART} not found"
      exit 1
    fi
  fi

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
    -O keyformat=hex \
    -O keylocation="file://${ZFS_KEYFILE}" \
    "$POOL_NAME" "$ZFS_PART"

  echo "Pool created."
fi

# --- Set cachefile ---
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

echo ""
zpool status "$POOL_NAME"
echo ""
zfs list -r "$POOL_NAME"
echo ""
echo "WARNING: Back up ${ZFS_KEYFILE} - without it, data is unrecoverable."
echo ""
echo "Next: run ansible zfs role to create datasets."
