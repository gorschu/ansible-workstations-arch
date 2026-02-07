#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dependencies ---
pacman -Sy --noconfirm --needed gum &>/dev/null

# --- Usage ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <disk>"
  echo "  e.g. $0 artemis /dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_xxx"
  exit 1
fi

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
HOSTNAME=$1
DISK=$2
LUKS_NAME=cryptroot
USERNAME=gorschu
TIMEZONE=Europe/Berlin
BTRFS_SIZE=20G

# --- Detect ZFS partition 9 ---
if sgdisk -p "$DISK" 2>/dev/null | awk '{print $1}' | grep -qx '9'; then
  ZFS_PRESERVE=true
  ZFS_START=$(sgdisk -i 9 "$DISK" | awk '/^First sector:/{print $3}')
  if [[ -z "$ZFS_START" || "$ZFS_START" -lt 1 ]]; then
    echo "ERROR: could not determine start sector of ZFS partition 9"
    exit 1
  fi
  echo "ZFS partition 9 found on ${DISK} — preserving (starts at sector ${ZFS_START})"
else
  ZFS_PRESERVE=false
  echo "No ZFS partition on ${DISK} — full wipe"
fi

if [[ "$ZFS_PRESERVE" == true ]]; then
  BTRFS_LABEL="fill to ZFS"
else
  BTRFS_LABEL="${BTRFS_SIZE}"
fi
LAYOUT="$(part "$DISK" 1) - 1G EFI (/boot)
$(part "$DISK" 2) - ${BTRFS_LABEL} LUKS2 + btrfs (@ @home)
$([[ "$ZFS_PRESERVE" == true ]] && echo "$(part "$DISK" 9) - ZFS (preserved)" || echo "rest free for ZFS")"

echo ""
gum style --border rounded --padding "0 1" --border-foreground 4 "$LAYOUT"
echo ""
gum confirm "Wipe and install?" || exit 1

# --- Partition ---
if [[ "$ZFS_PRESERVE" == true ]]; then
  for part in $(sgdisk -p "$DISK" | awk '/^ *[0-9]/ && $1 != 9 {print $1}'); do
    sgdisk -d "$part" "$DISK"
  done
else
  sgdisk -Z "$DISK"
fi
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
if [[ "$ZFS_PRESERVE" == true ]]; then
  sgdisk -n "2:0:$((ZFS_START - 1))" -t 2:8309 -c 2:cryptroot "$DISK"
else
  sgdisk -n 2:0:+${BTRFS_SIZE} -t 2:8309 -c 2:cryptroot "$DISK"
fi
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
echo "Setting up LUKS..."
cryptsetup luksFormat --type luks2 "$(part "$DISK" 2)"
cryptsetup open "$(part "$DISK" 2)" "$LUKS_NAME"

mkfs.btrfs /dev/mapper/"$LUKS_NAME"

# --- Btrfs subvols ---
mount /dev/mapper/"$LUKS_NAME" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

# --- Mount (ESP at /boot for systemd-boot) ---
mount -o subvol=@ /dev/mapper/"$LUKS_NAME" /mnt
mkdir -p /mnt/{home,boot}
mount -o subvol=@home /dev/mapper/"$LUKS_NAME" /mnt/home
mount "$(part "$DISK" 1)" /mnt/boot

# --- Rank mirrors ---
echo "Ranking Arch mirrors..."
reflector --protocol https --sort rate --latest 20 --country Germany,Netherlands,Sweden,Finland,Denmark,Austria,Switzerland --save /etc/pacman.d/mirrorlist

# --- Pacstrap ---
pacstrap /mnt \
  base base-devel linux linux-headers linux-lts linux-lts-headers linux-firmware \
  intel-ucode amd-ucode \
  cryptsetup btrfs-progs \
  dracut \
  networkmanager iwd wireless-regdb openssh \
  terminus-font \
  python \
  sudo neovim git

# --- Fstab ---
genfstab -U /mnt >>/mnt/etc/fstab
sed -i '/\/boot.*vfat/s/relatime/relatime,fmask=0077,dmask=0077/' /mnt/etc/fstab

# --- Static configs (rootfs overlay) ---
cp -r "$SCRIPT_DIR/rootfs/." /mnt/

# --- LUKS UUID for boot entries ---
LUKS_UUID=$(blkid -s UUID -o value "$(part "$DISK" 2)")

# --- systemd-boot entries ---
mkdir -p /mnt/boot/loader/entries

cat >/mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rd.luks.name=${LUKS_UUID}=${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} rootflags=subvol=@ rw
EOF

cat >/mnt/boot/loader/entries/arch-lts.conf <<EOF
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /initramfs-linux-lts.img
options rd.luks.name=${LUKS_UUID}=${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} rootflags=subvol=@ rw
EOF

# --- Passwords (before chroot — passwd needs a terminal) ---
ask_password() {
  local label=$1
  while true; do
    pw=$(gum input --password --header "Password for ${label}")
    pw_confirm=$(gum input --password --header "Confirm password for ${label}")
    [[ "$pw" == "$pw_confirm" ]] && break
    gum style --foreground 1 "Passwords don't match — try again."
  done
  echo "$pw"
}

USER_PASSWORD=$(ask_password "$USERNAME")

if gum confirm "Use the same password for root?"; then
  ROOT_PASSWORD="$USER_PASSWORD"
else
  ROOT_PASSWORD=$(ask_password "root")
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

# Bootloader
bootctl install

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
  "Done. Verify /mnt/boot/ has vmlinuz-linux + initramfs-linux.img, then:" \
  "" \
  "  umount -R /mnt" \
  "  cryptsetup close ${LUKS_NAME}" \
  "  reboot" \
  "" \
  "After reboot, run zfs-setup.sh to add ZFS support."
