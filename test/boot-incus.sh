#!/bin/bash
set -e

VM_NAME="arch-test"
INSTALLER_ISO="${1}"
DISK_SIZE="100GB"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() {
  echo -e "${RED}[!]${NC} $1"
  exit 1
}

# Check if ISO exists
[ -f "$INSTALLER_ISO" ] || error "Installer ISO not found: $INSTALLER_ISO"

# Delete existing VM if it exists
if incus list --format=csv | grep -q "^$VM_NAME,"; then
  warn "VM $VM_NAME already exists, deleting..."
  incus delete -f "$VM_NAME"
fi

log "Creating VM: $VM_NAME"
incus init --empty --vm "$VM_NAME"

log "Configuring VM..."
incus config set "$VM_NAME" limits.cpu=4
incus config set "$VM_NAME" limits.memory=8GB
incus config set "$VM_NAME" security.secureboot=false

log "Adding root disk ($DISK_SIZE) with WWN..."
incus config device add "$VM_NAME" root disk \
  path=/ \
  pool=default \
  size="$DISK_SIZE" \
  io.bus=virtio-scsi \
  wwn=0x5000c500a1b2c3d4

log "Attaching installer ISO..."
incus config device add "$VM_NAME" install-media disk \
  source="$(pwd)/$INSTALLER_ISO" \
  boot.priority=10

log "Starting VM..."
incus start "$VM_NAME"

log "VM started!"

# Connect to VGA console
exec incus console "$VM_NAME" --type=vga
