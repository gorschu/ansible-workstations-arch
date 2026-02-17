#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: $0 <hostname> <disk>"
  echo "  e.g. $0 artemis /dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_xxx"
}

# --- Required args (fail fast before doing any setup) ---
if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

HOSTNAME=$1
DISK=$2

if [[ -z "$HOSTNAME" ]]; then
  echo "ERROR: hostname is required."
  usage
  exit 1
fi

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
  echo "ERROR: disk must be an existing block device: '$DISK'"
  usage
  exit 1
fi

# --- Dependencies ---
pacman -Sy --noconfirm --needed gum &>/dev/null

# --- CachyOS repos (on live ISO, so pacstrap uses them) ---
echo "Setting up CachyOS repositories..."
curl -sL https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz
tar xJf /tmp/cachyos-repo.tar.xz -C /tmp
# Patch out the final pacman -Syu (we don't need to upgrade the live ISO, really)
sed -i 's/pacman -Syu/#pacman -Syu/' /tmp/cachyos-repo/cachyos-repo.sh
(cd /tmp/cachyos-repo && ./cachyos-repo.sh)
rm -rf /tmp/cachyos-repo /tmp/cachyos-repo.tar.xz

# Rank mirrors before pacstrap
pacman -Sy --noconfirm cachyos-rate-mirrors
echo "Ranking mirrors..."
cachyos-rate-mirrors

# --- Partition path helper ---
# /dev/sda → /dev/sda1, /dev/disk/by-id/foo → /dev/disk/by-id/foo-part1
part() {
  local disk=$1 num=$2
  if [[ "$disk" == /dev/sd* || "$disk" == /dev/vd* || "$disk" == /dev/nvme* ]]; then
    # nvme uses p suffix: /dev/nvme0n1p1, sd/vd use bare digits: /dev/sda1
    if [[ "$disk" == /dev/nvme* ]]; then
      echo "${disk}p${num}"
    else
      echo "${disk}${num}"
    fi
  else
    # by-id, by-path, etc. use -partN
    echo "${disk}-part${num}"
  fi
}

# --- Config ---
ROOT_LUKS_NAME=cryptroot
DATA_LUKS_NAME=cryptdata
USERNAME=gorschu
TIMEZONE=Europe/Berlin
ROOTFS_SIZE=150G
DATA_PART_NUM=9
ROOT_SUBVOL=root
HOME_SUBVOL=home
DATA_SUBVOL=data

ask_secret() {
  local label=$1
  local pw pw_confirm
  while true; do
    pw=$(gum input --password --header "Password for ${label}")
    pw_confirm=$(gum input --password --header "Confirm password for ${label}")
    [[ "$pw" == "$pw_confirm" ]] && break
    gum style --foreground 1 "Passwords don't match — try again."
  done
  echo "$pw"
}

# --- Detect persistent data partition 9 ---
if sgdisk -p "$DISK" 2>/dev/null | awk '{print $1}' | grep -qx "${DATA_PART_NUM}"; then
  DATA_PRESERVE=true
  DATA_START=$(sgdisk -i "${DATA_PART_NUM}" "$DISK" | awk '/^First sector:/{print $3}')
  if [[ -z "$DATA_START" || "$DATA_START" -lt 1 ]]; then
    echo "ERROR: could not determine start sector of data partition ${DATA_PART_NUM}"
    exit 1
  fi
  echo "Data partition ${DATA_PART_NUM} found on ${DISK} — preserving (starts at sector ${DATA_START})"
else
  DATA_PRESERVE=false
  echo "No data partition ${DATA_PART_NUM} on ${DISK} — it will be created as encrypted btrfs"
fi

if [[ "$DATA_PRESERVE" == true ]]; then
  ROOT_LABEL="fill to preserved data partition"
else
  ROOT_LABEL="${ROOTFS_SIZE}"
fi
LAYOUT="$(part "$DISK" 1) - 1G EFI (/boot)
$(part "$DISK" 2) - ${ROOT_LABEL} LUKS2 + btrfs (${ROOT_SUBVOL} ${HOME_SUBVOL})
$([[ "$DATA_PRESERVE" == true ]] && echo "$(part "$DISK" ${DATA_PART_NUM}) - LUKS2 + btrfs (${DATA_SUBVOL}) (preserved)" || echo "$(part "$DISK" ${DATA_PART_NUM}) - LUKS2 + btrfs (${DATA_SUBVOL}) (created from remaining space)")"

echo ""
gum style --border rounded --padding "0 1" --border-foreground 4 "$LAYOUT"
echo ""
gum confirm "Wipe and install?" || exit 1

# Ask once and reuse for root + data setup.
echo ""
echo "Setting up LUKS passphrase for root and persistent data..."
LUKS_PASSWORD=$(ask_secret "disk encryption (shared root + data)")
DATA_PART=$(part "$DISK" "${DATA_PART_NUM}")

# Validate preserved part9 before any destructive partitioning.
if [[ "$DATA_PRESERVE" == true ]]; then
  DATA_PART_TYPE=$(blkid -s TYPE -o value "$DATA_PART" || true)
  if [[ "$DATA_PART_TYPE" != "crypto_LUKS" ]]; then
    echo "ERROR: preserved ${DATA_PART} is not LUKS (found: ${DATA_PART_TYPE:-unknown})"
    echo "Aborting install before partitioning to protect preserved data partition."
    exit 1
  fi

  if cryptsetup status "$DATA_LUKS_NAME" >/dev/null 2>&1; then
    cryptsetup close "$DATA_LUKS_NAME" || true
  fi

  if ! printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file - "$DATA_PART" "$DATA_LUKS_NAME"; then
    echo "ERROR: could not unlock preserved ${DATA_PART} as ${DATA_LUKS_NAME}"
    echo "Use the existing data LUKS passphrase (root and data should match)."
    exit 1
  fi

  DATA_FS_TYPE=$(blkid -s TYPE -o value /dev/mapper/"$DATA_LUKS_NAME" || true)
  cryptsetup close "$DATA_LUKS_NAME" || true
  if [[ "$DATA_FS_TYPE" != "btrfs" ]]; then
    echo "ERROR: preserved ${DATA_PART} is LUKS, but inner filesystem is not btrfs (found: ${DATA_FS_TYPE:-unknown})"
    echo "Aborting install before partitioning to protect preserved data partition."
    exit 1
  fi
fi

# --- Partition ---
if [[ "$DATA_PRESERVE" == true ]]; then
  for part in $(sgdisk -p "$DISK" | awk -v keep="${DATA_PART_NUM}" '/^ *[0-9]/ && $1 != keep {print $1}'); do
    sgdisk -d "$part" "$DISK"
  done
else
  sgdisk -Z "$DISK"
fi
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
if [[ "$DATA_PRESERVE" == true ]]; then
  sgdisk -n "2:0:$((DATA_START - 1))" -t 2:8309 -c 2:cryptroot "$DISK"
else
  sgdisk -n 2:0:+${ROOTFS_SIZE} -t 2:8309 -c 2:cryptroot "$DISK"
  sgdisk -n "${DATA_PART_NUM}:0:0" -t "${DATA_PART_NUM}:8309" -c "${DATA_PART_NUM}:cryptdata" "$DISK"
fi
sgdisk -c "${DATA_PART_NUM}:cryptdata" "$DISK"
partprobe "$DISK"
sleep 1

# --- Clean EFI boot entries ---
echo "Cleaning EFI boot entries..."
while read -r entry; do
  efibootmgr -q -Bb "$entry" || true
done < <(efibootmgr 2>/dev/null | grep -oP 'Boot\K[0-9A-F]{4}' || true)

# --- Filesystems ---
mkfs.fat -F32 "$(part "$DISK" 1)"

echo ""
echo "Configuring LUKS and btrfs..."

printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$(part "$DISK" 2)"
printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file - "$(part "$DISK" 2)" "$ROOT_LUKS_NAME"
mkfs.btrfs /dev/mapper/"$ROOT_LUKS_NAME"

# --- Btrfs subvols ---
mount /dev/mapper/"$ROOT_LUKS_NAME" /mnt
btrfs subvolume create "/mnt/${ROOT_SUBVOL}"
btrfs subvolume create "/mnt/${HOME_SUBVOL}"
umount /mnt

# --- Persistent data partition (part9) ---
if [[ "$DATA_PRESERVE" != true ]]; then
  printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$DATA_PART"
fi

if ! printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file - "$DATA_PART" "$DATA_LUKS_NAME"; then
  echo "ERROR: could not unlock ${DATA_PART} as ${DATA_LUKS_NAME}"
  echo "Ensure root/data use the same LUKS passphrase."
  exit 1
fi

DATA_MAPPER_DEV=/dev/mapper/"$DATA_LUKS_NAME"

if [[ "$DATA_PRESERVE" != true ]]; then
  mkfs.btrfs "$DATA_MAPPER_DEV"
fi

mkdir -p /mnt/data_setup
mount "$DATA_MAPPER_DEV" /mnt/data_setup
if ! btrfs subvolume list /mnt/data_setup | awk '{print $NF}' | grep -qx "${DATA_SUBVOL}"; then
  btrfs subvolume create "/mnt/data_setup/${DATA_SUBVOL}"
fi
umount /mnt/data_setup
rmdir /mnt/data_setup
cryptsetup close "$DATA_LUKS_NAME"
unset LUKS_PASSWORD

# --- Mount (ESP at /boot for systemd-boot) ---
mount -o subvol="${ROOT_SUBVOL}" /dev/mapper/"$ROOT_LUKS_NAME" /mnt
mkdir -p /mnt/{home,boot}
mount -o subvol="${HOME_SUBVOL}" /dev/mapper/"$ROOT_LUKS_NAME" /mnt/home
mkdir -p "/mnt/home/${USERNAME}/data"
mount "$(part "$DISK" 1)" /mnt/boot

# --- Pacstrap (from CachyOS repos) ---
pacstrap /mnt \
  base base-devel linux-firmware \
  cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist \
  linux-cachyos linux-cachyos-headers \
  linux-cachyos-lts-lto linux-cachyos-lts-lto-headers \
  linux-cachyos-zfs linux-cachyos-lts-lto-zfs zfs-utils \
  intel-ucode amd-ucode \
  cryptsetup btrfs-progs \
  dracut cpio busybox tpm2-tools \
  networkmanager iwd wireless-regdb openssh \
  terminus-font \
  python \
  cachyos-settings cachyos-rate-mirrors \
  sudo neovim git

# --- Fstab ---
genfstab -U /mnt >>/mnt/etc/fstab
sed -i '/\/boot.*vfat/s/relatime/relatime,fmask=0077,dmask=0077/' /mnt/etc/fstab

# --- CachyOS pacman conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

# --- Static configs (rootfs overlay) ---
cp -r "$SCRIPT_DIR/rootfs/." /mnt/

# --- LUKS UUIDs for boot entries ---
ROOT_LUKS_UUID=$(blkid -s UUID -o value "$(part "$DISK" 2)")
DATA_LUKS_UUID=$(blkid -s UUID -o value "$DATA_PART")

# --- systemd-boot entries ---
mkdir -p /mnt/boot/loader/entries

cat >/mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux (CachyOS)
linux /vmlinuz-linux-cachyos
initrd /initramfs-linux-cachyos.img
options rd.luks.name=${ROOT_LUKS_UUID}=${ROOT_LUKS_NAME} rd.luks.name=${DATA_LUKS_UUID}=${DATA_LUKS_NAME} root=/dev/mapper/${ROOT_LUKS_NAME} rootflags=subvol=${ROOT_SUBVOL} rw
EOF

cat >/mnt/boot/loader/entries/arch-lts.conf <<EOF
title Arch Linux LTS (CachyOS)
linux /vmlinuz-linux-cachyos-lts-lto
initrd /initramfs-linux-cachyos-lts-lto.img
options rd.luks.name=${ROOT_LUKS_UUID}=${ROOT_LUKS_NAME} rd.luks.name=${DATA_LUKS_UUID}=${DATA_LUKS_NAME} root=/dev/mapper/${ROOT_LUKS_NAME} rootflags=subvol=${ROOT_SUBVOL} rw
EOF

# --- Passwords (before chroot — passwd needs a terminal) ---
USER_PASSWORD=$(ask_secret "$USERNAME")

if gum confirm "Use the same password for root?"; then
  ROOT_PASSWORD="$USER_PASSWORD"
else
  ROOT_PASSWORD=$(ask_secret "root")
fi

# --- Chroot ---
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

# Locale
cat > /etc/locale.gen <<LOCALE
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
LOCALE
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Time
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# User
groupadd -g 1000 ${USERNAME}
useradd -m -u 1000 -g 1000 -G wheel -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}" | chpasswd

# Sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Rank mirrors
echo "Ranking mirrors..."
cachyos-rate-mirrors

# Bootloader
bootctl install

# Regenerate initramfs (dracut ran during pacstrap before configs were in place)
dracut --force --regenerate-all

# Services
systemctl enable iwd
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable fstrim.timer
CHROOT

if [[ $? -ne 0 ]]; then
  echo "ERROR: chroot failed — check output above."
  exit 1
fi

# --- DNS (systemd-resolved stub, must be outside chroot — arch-chroot bind-mounts resolv.conf) ---
rm -f /mnt/etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo ""
gum style --border rounded --padding "0 1" --border-foreground 2 \
  "Done. Verify /mnt/boot/ has vmlinuz-linux-cachyos + initramfs-linux-cachyos.img, then:" \
  "" \
  "  umount -R /mnt" \
  "  cryptsetup close ${ROOT_LUKS_NAME}" \
  "  reboot" \
  "" \
  "ZFS kernel modules remain installed, but default workstation data uses encrypted btrfs on part9."
