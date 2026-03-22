#!/bin/bash
#
# Arch Linux Full Disk Encryption Installation Script
# =====================================================
# Threat model: stolen/lost laptop — disk inaccessible without passphrase
#
# Stack:
#   UEFI → systemd-boot → unencrypted ESP (/boot) → LUKS2 → ext4 (/)
#   Initramfs: systemd-based (sd-encrypt, no busybox)
#   No swap, no LVM, two partitions only
#
# Prerequisites:
#   - Booted into Arch ISO (UEFI mode)
#   - Internet connection (use iwctl for wifi if needed)
#   - Identify your target disk (lsblk)
#
# Usage:
#   1. Review and set the variables below
#   2. Run individual sections manually, or source this script as a reference
#   3. This script is intentionally NOT fully automatic — FDE setup deserves
#      your attention at each step
#
# !! WARNING: This will DESTROY all data on the target disk !!
#

set -euo pipefail

# =============================================================================
# CONFIGURATION — Review and adjust these before running anything
# =============================================================================

DISK="/dev/nvme0n1"              # Target disk — use 'lsblk' to identify
                              # NVMe drives are typically /dev/nvme0n1
HOSTNAME="archlinux"            # Machine hostname
USERNAME="user"               # Non-root user to create
TIMEZONE="Europe/Berlin"      # timedatectl list-timezones
LOCALE="en_gb.UTF-8"          # Locale
KEYMAP="de-latin1-nodeadkeys"                   # Console keymap (loadkeys)

# Partition naming — adjust for NVMe (e.g., /dev/nvme0n1p1, /dev/nvme0n1p2)
# For SATA/USB drives it's /dev/sdX1, /dev/sdX2
PART_EFI="${DISK}p1"           # EFI System Partition
PART_ROOT="${DISK}p2"          # LUKS partition (will hold root)
CRYPT_NAME="cryptdev"        # dm-crypt mapped device name

# =============================================================================
# STEP 0: Verify UEFI mode
# =============================================================================

echo "=== Step 0: Verifying UEFI boot mode ==="
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "ERROR: Not booted in UEFI mode. This script requires UEFI."
    exit 1
fi
echo "UEFI mode confirmed."

# =============================================================================
# STEP 1: Partition the disk
# =============================================================================
# Two partitions:
#   1. EFI System Partition (ESP) — 512 MiB, FAT32
#   2. Linux root — rest of disk, will become LUKS container
# =============================================================================

echo ""
echo "=== Step 1: Partitioning ${DISK} ==="
echo "!! This will destroy all data on ${DISK} !!"
echo ""
read -rp "Type 'yes' to continue: " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# Wipe existing partition table and create GPT
sgdisk --zap-all "$DISK"

# Partition 1: EFI System Partition, 512 MiB
sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"ESP" "$DISK"

# Partition 2: Linux root, remaining space
sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:"cryptroot" "$DISK"

# Inform kernel of partition table changes
partprobe "$DISK"

echo "Partitioning complete."
lsblk "$DISK"

# =============================================================================
# STEP 2: Set up LUKS2 encryption
# =============================================================================
# Uses LUKS2 with argon2id (default). You will be prompted for your passphrase.
# Pick a strong one — 4-5 random words (diceware) is ideal.
# =============================================================================

echo ""
echo "=== Step 2: Setting up LUKS2 encryption on ${PART_ROOT} ==="
echo "You will be asked to set your encryption passphrase."
echo ""

cryptsetup luksFormat --type luks2 "$PART_ROOT"

echo ""
echo "Now opening the LUKS container..."
cryptsetup open "$PART_ROOT" "$CRYPT_NAME"

echo "LUKS container opened at /dev/mapper/${CRYPT_NAME}"

# =============================================================================
# STEP 3: Format filesystems
# =============================================================================

echo ""
echo "=== Step 3: Formatting filesystems ==="

# ESP — must be FAT32
mkfs.fat -F32 "$PART_EFI"

# Root — ext4 on the opened LUKS container
mkfs.ext4 /dev/mapper/"$CRYPT_NAME"

echo "Filesystems created."

# =============================================================================
# STEP 4: Mount filesystems
# =============================================================================

echo ""
echo "=== Step 4: Mounting filesystems ==="

mount /dev/mapper/"$CRYPT_NAME" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

echo "Mounted:"
echo "  /dev/mapper/${CRYPT_NAME} → /mnt      (ext4, encrypted)"
echo "  ${PART_EFI}               → /mnt/boot (FAT32, unencrypted ESP)"

# =============================================================================
# STEP 5: Install base system
# =============================================================================

echo ""
echo "=== Step 5: Installing base system (pacstrap) ==="

pacstrap -K /mnt base linux linux-firmware \
    systemd \
    e2fsprogs dosfstools \
    networkmanager \
    vim nano \
    sudo

echo "Base system installed."

# =============================================================================
# STEP 6: Generate fstab
# =============================================================================

echo ""
echo "=== Step 6: Generating fstab ==="

genfstab -U /mnt >> /mnt/etc/fstab

echo "Generated /mnt/etc/fstab:"
cat /mnt/etc/fstab

# =============================================================================
# STEP 7: Chroot and configure
# =============================================================================
# Everything below runs inside the new system via arch-chroot.
# We write a config script and execute it.
# =============================================================================

echo ""
echo "=== Step 7: Configuring system (chroot) ==="

# Get the UUID of the LUKS partition (the raw partition, not the mapped device)
LUKS_UUID=$(blkid -s UUID -o value "$PART_ROOT")
echo "LUKS partition UUID: ${LUKS_UUID}"

cat > /mnt/chroot-config.sh << CHROOT_EOF
#!/bin/bash
set -euo pipefail

# --- Timezone ---
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# --- Locale ---
sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# --- Hostname ---
echo "${HOSTNAME}" > /etc/hostname

# --- mkinitcpio: switch to systemd-based initramfs ---
# Replace the default HOOKS line with systemd-based hooks.
#
# What each hook does:
#   systemd      — systemd as init in initramfs (replaces base + udev)
#   autodetect   — reduces initramfs to only needed modules
#   modconf      — loads modprobe config
#   kms          — early KMS for display
#   keyboard     — keyboard drivers (needed to type passphrase)
#   sd-vconsole  — applies keymap/font in systemd initrd (replaces keymap + consolefont)
#   block        — block device modules
#   sd-encrypt   — LUKS unlocking via systemd (replaces encrypt)
#   filesystems  — filesystem modules
#   fsck         — filesystem check

sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Regenerate initramfs
mkinitcpio -P

# --- bootloader: systemd-boot ---
bootctl install

# --- Boot loader configuration ---
# The loader.conf sets defaults
cat > /boot/loader/loader.conf << LOADER
default arch.conf
timeout 3
console-mode max
editor  no
LOADER

# The actual boot entry
# sd-encrypt uses rd.luks.name=<UUID>=<mapped-name> syntax
cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME} rw
ENTRY

# --- Fallback entry (uses fallback initramfs) ---
cat > /boot/loader/entries/arch-fallback.conf << ENTRY
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME} rw
ENTRY

# --- Enable NetworkManager ---
systemctl enable NetworkManager

# --- Root password ---
echo ""
echo "Set the root password:"
passwd

# --- Create user ---
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo ""
echo "Set password for ${USERNAME}:"
passwd ${USERNAME}

# --- Enable sudo for wheel group ---
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ""
echo "=== Chroot configuration complete ==="

CHROOT_EOF

chmod +x /mnt/chroot-config.sh
arch-chroot /mnt /chroot-config.sh
rm /mnt/chroot-config.sh

# =============================================================================
# STEP 8: Done
# =============================================================================

echo ""
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo ""
echo "  Disk layout:"
echo "    ${PART_EFI}  → /boot  (ESP, FAT32, unencrypted)"
echo "    ${PART_ROOT} → LUKS2 → /dev/mapper/${CRYPT_NAME} → /  (ext4)"
echo ""
echo "  Boot chain:"
echo "    UEFI → systemd-boot → sd-encrypt (passphrase) → root"
echo ""
echo "  Next steps:"
echo "    1. umount -R /mnt"
echo "    2. reboot"
echo "    3. Remove the installation media"
echo "    4. Enter your LUKS passphrase at the systemd prompt"
echo ""
echo "  If you need to access this system from the ISO again:"
echo "    cryptsetup open ${PART_ROOT} ${CRYPT_NAME}"
echo "    mount /dev/mapper/${CRYPT_NAME} /mnt"
echo "    mount ${PART_EFI} /mnt/boot"
echo "    arch-chroot /mnt"
echo ""
