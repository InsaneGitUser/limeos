#!/bin/bash
# =============================================================================
#  LimeOS Installer
#  Run from Arch Linux live ISO:
#    bash <(curl -s https://raw.githubusercontent.com/InsaneGitUser/My-Shit/main/install.sh)
#
#  Requires: internet connection (connect wifi with iwctl before running)
#
#  Partitioning:
#    Full disk  — script does everything automatically:
#                 UEFI: 1MB gap + 512MB ESP (FAT32) + root (ext4)
#                 BIOS: 1MB BIOS boot + root (ext4)
#    Dual boot  — user carves free space in cfdisk, then picks root partition.
#                 Script auto-creates BIOS boot or detects/creates ESP.
# =============================================================================

set -e

REPO="https://raw.githubusercontent.com/InsaneGitUser/My-Shit/main"
PACKAGES_URL="$REPO/packages.txt"
CONFIG_URL="$REPO/config.tar.gz"
START_ICON_URL="$REPO/start.png"
NEW_USER="lime"
TARGET="/mnt"
LOG="/tmp/limeos-install.log"

SERVICES=(
    NetworkManager
    sddm
    iwd
)

# ── COLORS ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLD='\033[1m'
RST='\033[0m'

# ── LOGGING ───────────────────────────────────────────────────────────────────
log()  { echo -e "${GRN}[$(date +%T)]${RST} $*" | tee -a "$LOG"; }
warn() { echo -e "${YLW}[$(date +%T)] WARN:${RST} $*" | tee -a "$LOG"; }
die()  { echo -e "${RED}[$(date +%T)] ERROR:${RST} $*" | tee -a "$LOG"; exit 1; }

# ── HEADER ────────────────────────────────────────────────────────────────────
clear
echo -e "${BLD}"
echo "  ██╗     ██╗███╗   ███╗███████╗ ██████╗ ███████╗"
echo "  ██║     ██║████╗ ████║██╔════╝██╔═══██╗██╔════╝"
echo "  ██║     ██║██╔████╔██║█████╗  ██║   ██║███████╗"
echo "  ██║     ██║██║╚██╔╝██║██╔══╝  ██║   ██║╚════██║"
echo "  ███████╗██║██║ ╚═╝ ██║███████╗╚██████╔╝███████║"
echo "  ╚══════╝╚═╝╚═╝     ╚═╝╚══════╝ ╚═════╝ ╚══════╝"
echo -e "${RST}"
echo -e "  ${BLD}LimeOS Installer${RST} — Arch-based"
echo ""

# ── INSTALL DIALOG ────────────────────────────────────────────────────────────
if ! command -v dialog >/dev/null 2>&1; then
    echo -e "${BLD}Installing dialog...${RST}"
    pacman -Sy --noconfirm dialog \
        || { echo -e "${RED}Failed to install dialog — check internet.${RST}"; exit 1; }
fi

# ── DEPENDENCY CHECK ──────────────────────────────────────────────────────────
for cmd in pacstrap arch-chroot parted mkfs.fat mkfs.ext4 blkid lsblk \
           sgdisk partprobe dialog curl cfdisk; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Missing: $cmd — are you running from the Arch live ISO?"
done

# ── HELPERS ───────────────────────────────────────────────────────────────────
detect_firmware() {
    [ -d /sys/firmware/efi ] && echo "uefi" || echo "bios"
}

parent_disk() {
    echo "$1" | sed \
        -e 's|\(nvme[0-9]*n[0-9]*\)p[0-9][0-9]*$|\1|' \
        -e 's|\(mmcblk[0-9]*\)p[0-9][0-9]*$|\1|' \
        -e 's|[0-9][0-9]*$||'
}

pick_disk() {
    local prompt="$1"
    local -a args=()
    while IFS= read -r line; do
        local name size model
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        model=$(awk '{$1=$2=""; gsub(/^[[:space:]]+/,"",$0); print}' <<< "$line")
        args+=("/dev/$name" "$size ${model:-Unknown}")
    done < <(lsblk -dno NAME,SIZE,MODEL | grep -v '^loop\|^sr')
    [ ${#args[@]} -eq 0 ] && die "No disks found."
    dialog --stdout --title "LimeOS Installer" --menu "$prompt" 20 76 12 "${args[@]}"
}

pick_partition() {
    local disk="$1" prompt="$2"
    local -a args=()
    while IFS= read -r line; do
        local name size fs label
        name=$(awk '{print $1}'  <<< "$line")
        size=$(awk '{print $2}'  <<< "$line")
        fs=$(awk '{print $3}'    <<< "$line")
        label=$(awk '{print $4}' <<< "$line")
        local desc="$size"
        [ -n "$fs"    ] && desc="$desc [$fs]"
        [ -n "$label" ] && desc="$desc \"$label\""
        args+=("$name" "$desc")
    done < <(lsblk -pno NAME,SIZE,FSTYPE,LABEL,TYPE \
        | awk '$5=="part"' \
        | grep "^${disk}")
    [ ${#args[@]} -eq 0 ] && return 1
    dialog --stdout --title "LimeOS Installer" --menu "$prompt" 20 76 12 "${args[@]}"
}

# ── DETECT FIRMWARE ───────────────────────────────────────────────────────────
FIRMWARE=$(detect_firmware)
log "Firmware: $FIRMWARE"

# ── INSTALL MODE ──────────────────────────────────────────────────────────────
INSTALL_MODE=$(dialog --stdout --title "LimeOS Installer" \
    --radiolist "Installation mode:" 10 70 2 \
    "fulldisk"  "Full disk — erase entire disk, automatic partitioning" "on" \
    "dualboot"  "Dual boot — keep existing OS, install alongside it"    "off") \
    || die "Cancelled."
log "Mode: $INSTALL_MODE"

# ── PICK DISK ─────────────────────────────────────────────────────────────────
if [ "$INSTALL_MODE" = "fulldisk" ]; then
    TARGET_DISK=$(pick_disk "WARNING: entire disk will be ERASED:") \
        || die "Cancelled."
    dialog --title "LimeOS Installer" \
        --yesno "ERASE ALL DATA on $TARGET_DISK?\n\nThis cannot be undone." 8 50 \
        || die "Aborted."
else
    TARGET_DISK=$(pick_disk "Select the disk that has free space for LimeOS:") \
        || die "Cancelled."
fi
log "Disk: $TARGET_DISK"

# ── PARTITION ─────────────────────────────────────────────────────────────────
TARGET_ESP=""
TARGET_PART=""

if [ "$INSTALL_MODE" = "fulldisk" ]; then
    log "Wiping $TARGET_DISK"
    dd if=/dev/zero of="$TARGET_DISK" bs=512 count=2048 2>/dev/null || true
    sync

    if [ "$FIRMWARE" = "uefi" ]; then
        log "Partitioning for UEFI: 1MiB gap + 512MiB ESP + root"
        parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart ESP  fat32 1MiB   513MiB \
            set 1 esp on \
            mkpart ROOT ext4  513MiB 100%
        partprobe "$TARGET_DISK"; sleep 2
        TARGET_ESP=$(lsblk -rno NAME "$TARGET_DISK" \
            | grep -v "^$(basename "$TARGET_DISK")$" \
            | awk 'NR==1{print "/dev/" $1}')
        TARGET_PART=$(lsblk -rno NAME "$TARGET_DISK" \
            | grep -v "^$(basename "$TARGET_DISK")$" \
            | awk 'NR==2{print "/dev/" $1}')
        [ -b "$TARGET_ESP" ]  || die "ESP not found after partitioning"
        [ -b "$TARGET_PART" ] || die "Root partition not found after partitioning"
        log "Formatting ESP $TARGET_ESP as FAT32"
        mkfs.fat -F32 -n EFI "$TARGET_ESP"
    else
        log "Partitioning for BIOS: 1MiB BIOS boot + root"
        parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart biosboot 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart ROOT ext4 2MiB 100%
        partprobe "$TARGET_DISK"; sleep 2
        TARGET_PART=$(lsblk -rno NAME "$TARGET_DISK" \
            | grep -v "^$(basename "$TARGET_DISK")$" \
            | awk 'NR==2{print "/dev/" $1}')
        [ -b "$TARGET_PART" ] || die "Root partition not found after partitioning"
        # BIOS boot partition is never formatted — GRUB writes to it directly
    fi

else
    # ── DUAL BOOT ─────────────────────────────────────────────────────────────
    dialog --title "LimeOS Installer" --msgbox \
"Next, cfdisk will open so you can create a partition in the free space.

Just create ONE new partition using the free space and set its
type to 'Linux filesystem'. Do not touch existing partitions.

$([ "$FIRMWARE" = "bios" ] && echo "BIOS mode: The 1MB BIOS boot partition will be
created automatically — you do not need to make it.")" 14 62

    clear
    echo -e "${BLD}Launching cfdisk — create your root partition in free space, then quit.${RST}"
    sleep 1
    cfdisk "$TARGET_DISK"

    # Let user pick which partition they just created
    TARGET_PART=$(pick_partition "$TARGET_DISK" \
        "Select the partition you just created for LimeOS root:") \
        || die "No partitions found on $TARGET_DISK."

    dialog --title "LimeOS Installer" \
        --yesno "Format $TARGET_PART as ext4 and install LimeOS onto it?\n\nAll data on this partition will be lost." 8 62 \
        || die "Aborted."

    if [ "$FIRMWARE" = "uefi" ]; then
        # Look for existing ESP
        existing_esp=$(lsblk -pno NAME,PARTTYPE "$TARGET_DISK" 2>/dev/null \
            | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" \
            | awk '{print $1}' | head -1 || true)
        if [ -n "$existing_esp" ]; then
            esz=$(lsblk -no SIZE "$existing_esp" | head -1)
            choice=$(dialog --stdout --title "LimeOS Installer" \
                --radiolist "EFI System Partition:" 10 72 2 \
                "use"  "Use existing $existing_esp ($esz) — recommended for dual boot" "on" \
                "new"  "Create new ESP — only if no other OS on this disk"              "off") \
                || die "Cancelled."
            [ "$choice" = "use" ] && TARGET_ESP="$existing_esp" || TARGET_ESP=""
        else
            dialog --title "LimeOS Installer" --msgbox \
"No EFI System Partition was found on $TARGET_DISK.

A new 512MB ESP will be created in free space using sgdisk.
Make sure at least 512MB of unallocated space remains on the disk." 10 60
        fi

        # Create ESP if needed
        if [ -z "$TARGET_ESP" ]; then
            log "Creating 512MB ESP on $TARGET_DISK"
            local next
            next=$(sgdisk -p "$TARGET_DISK" 2>/dev/null \
                | awk '/^[[:space:]]+[0-9]/{n=$1} END{print n+0+1}')
            [ -z "$next" ] && next=2
            sgdisk -n "${next}:0:+512M" -t "${next}:EF00" -c "${next}:EFI" \
                "$TARGET_DISK" \
                || die "sgdisk failed — not enough free space for 512MB ESP"
            partprobe "$TARGET_DISK"; sleep 2
            TARGET_ESP=$(lsblk -pno NAME,PARTTYPE "$TARGET_DISK" \
                | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" \
                | awk '{print $1}' | tail -1)
            [ -n "$TARGET_ESP" ] || die "ESP not found after creation"
            mkfs.fat -F32 -n EFI "$TARGET_ESP"
            log "New ESP: $TARGET_ESP"
        fi

    else
        # BIOS dual boot — add 1MB BIOS boot partition in free space
        log "Creating 1MB BIOS boot partition on $TARGET_DISK"
        next=$(sgdisk -p "$TARGET_DISK" 2>/dev/null \
            | awk '/^[[:space:]]+[0-9]/{n=$1} END{print n+0+1}')
        [ -z "$next" ] && next=2
        sgdisk -n "${next}:0:+1M" -t "${next}:EF02" -c "${next}:BIOS boot" \
            "$TARGET_DISK" \
            || die "sgdisk failed — not enough free space for BIOS boot partition"
        partprobe "$TARGET_DISK"; sleep 2
        log "BIOS boot partition created"
    fi
fi

log "Partitioning done: ROOT=$TARGET_PART ESP=${TARGET_ESP:-none}"

# ── FORMAT ROOT ───────────────────────────────────────────────────────────────
log "Formatting $TARGET_PART as ext4"
mkfs.ext4 -F -L "LimeOS" "$TARGET_PART" || die "mkfs.ext4 failed"

# Format ESP only if we just created it fresh (skip if reusing Windows ESP)
if [ "$FIRMWARE" = "uefi" ] && [ -n "$TARGET_ESP" ]; then
    existing_fs=$(lsblk -no FSTYPE "$TARGET_ESP" 2>/dev/null | head -1)
    if [ "$existing_fs" != "vfat" ]; then
        log "Formatting $TARGET_ESP as FAT32"
        mkfs.fat -F32 -n EFI "$TARGET_ESP" || die "mkfs.fat failed"
    else
        log "ESP already FAT32 — skipping format (preserving existing boot entries)"
    fi
fi

# ── MOUNT ─────────────────────────────────────────────────────────────────────
log "Mounting filesystems"
mount "$TARGET_PART" "$TARGET"
if [ "$FIRMWARE" = "uefi" ] && [ -n "$TARGET_ESP" ]; then
    mkdir -p "$TARGET/boot/efi"
    mount "$TARGET_ESP" "$TARGET/boot/efi"
    log "ESP mounted at $TARGET/boot/efi"
fi

# ── HOSTNAME ──────────────────────────────────────────────────────────────────
HOSTNAME=$(dialog --stdout --title "LimeOS Installer" \
    --inputbox "Enter a hostname for this machine:" 8 50) \
    || die "Cancelled."
[ -z "$HOSTNAME" ] && HOSTNAME="limeos"

# ── FINAL CONFIRM ─────────────────────────────────────────────────────────────
esp_line="  ESP:       ${TARGET_ESP:-N/A (BIOS mode)}"
dialog --title "LimeOS Installer" --yesno \
"Ready to install. Summary:

  Firmware:  $FIRMWARE
  Mode:      $INSTALL_MODE
  Disk:      $TARGET_DISK
  Root:      $TARGET_PART
$esp_line
  Hostname:  $HOSTNAME
  User:      $NEW_USER

Proceed? This will now download and install LimeOS." 17 56 || die "Aborted."

# ── PACSTRAP ──────────────────────────────────────────────────────────────────
do_pacstrap() {
    log "Fetching package list"
    local pkglist; pkglist=$(mktemp /tmp/pkglist.XXXXXX)
    curl -fsSL "$PACKAGES_URL" -o "$pkglist" \
        || die "Failed to fetch packages.txt"

    local -a pkgs=()
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        pkgs+=("$pkg")
    done < "$pkglist"
    rm -f "$pkglist"

    [ ${#pkgs[@]} -eq 0 ] && die "packages.txt is empty"
    log "Installing ${#pkgs[@]} packages"

    pacstrap -K --config /etc/pacman.conf "$TARGET" \
        base base-devel linux linux-firmware \
        grub os-prober efibootmgr networkmanager \
        "${pkgs[@]}" \
        >> "$LOG" 2>&1 \
        || die "pacstrap failed — check $LOG"

    log "pacstrap complete."
}

# ── CHROOT SETUP ──────────────────────────────────────────────────────────────
do_chroot() {
    log "Configuring system"

    genfstab -U "$TARGET" >> "$TARGET/etc/fstab"

    arch-chroot "$TARGET" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    arch-chroot "$TARGET" hwclock --systohc

    echo "en_US.UTF-8 UTF-8" >> "$TARGET/etc/locale.gen"
    arch-chroot "$TARGET" locale-gen >> "$LOG" 2>&1
    echo "LANG=en_US.UTF-8" > "$TARGET/etc/locale.conf"

    echo "$HOSTNAME" > "$TARGET/etc/hostname"
    cat > "$TARGET/etc/hosts" <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

    # Enable multilib in new install for steam and 32-bit packages
    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' "$TARGET/etc/pacman.conf"

    for svc in "${SERVICES[@]}"; do
        arch-chroot "$TARGET" systemctl enable "$svc" >> "$LOG" 2>&1 \
            && log "  Enabled $svc" \
            || warn "  Could not enable $svc"
    done

    echo ""
    echo -e "${BLD}Set password for root:${RST}"
    arch-chroot "$TARGET" passwd

    log "Creating user: $NEW_USER"
    arch-chroot "$TARGET" useradd -m \
        -G wheel,audio,video,storage,optical,input \
        -s /bin/bash "$NEW_USER"
    echo ""
    echo -e "${BLD}Set password for $NEW_USER:${RST}"
    arch-chroot "$TARGET" passwd "$NEW_USER"

    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        "$TARGET/etc/sudoers"

    log "Installing GRUB"
    if [ "$FIRMWARE" = "uefi" ]; then
        arch-chroot "$TARGET" grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=LimeOS \
            >> "$LOG" 2>&1 || die "grub-install (UEFI) failed"
    else
        arch-chroot "$TARGET" grub-install \
            --target=i386-pc \
            "$TARGET_DISK" \
            >> "$LOG" 2>&1 || die "grub-install (BIOS) failed"
    fi

    echo "GRUB_DISABLE_OS_PROBER=false" >> "$TARGET/etc/default/grub"
    arch-chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg \
        >> "$LOG" 2>&1 || die "grub-mkconfig failed"

    log "Chroot setup complete."
}

# ── APPLY CONFIG ──────────────────────────────────────────────────────────────
do_config() {
    log "Downloading config.tar.gz"
    local tarball; tarball=$(mktemp /tmp/config.XXXXXX.tar.gz)
    curl -fsSL "$CONFIG_URL" -o "$tarball" \
        || die "Failed to download config.tar.gz"

    log "Extracting config bundle"
    local extract; extract=$(mktemp -d /tmp/config.XXXXXX)
    tar -xzf "$tarball" -C "$extract" || die "Failed to extract config.tar.gz"
    rm -f "$tarball"

    local bundle="$extract"
    [ -d "$extract/limeos-config" ] && bundle="$extract/limeos-config"

    local user_home="$TARGET/home/$NEW_USER"

    if [ -d "$bundle/config" ]; then
        log "  Applying ~/.config"
        mkdir -p "$user_home/.config"
        cp -r "$bundle/config/." "$user_home/.config/"
    fi

    if [ -d "$bundle/local-share" ]; then
        log "  Applying ~/.local/share"
        mkdir -p "$user_home/.local/share"
        cp -r "$bundle/local-share/." "$user_home/.local/share/"
    fi

    if [ -d "$bundle/system-themes" ]; then
        log "  Applying system themes"
        [ -d "$bundle/system-themes/desktoptheme" ] && \
            cp -r "$bundle/system-themes/desktoptheme" "$TARGET/usr/share/plasma/"
        [ -d "$bundle/system-themes/color-schemes" ] && \
            cp -r "$bundle/system-themes/color-schemes" "$TARGET/usr/share/"
        [ -d "$bundle/system-themes/icons" ] && \
            cp -r "$bundle/system-themes/icons" "$TARGET/usr/share/"
        [ -d "$bundle/system-themes/themes" ] && \
            cp -r "$bundle/system-themes/themes" "$TARGET/usr/share/"
        [ -d "$bundle/system-themes/aurorae" ] && \
            cp -r "$bundle/system-themes/aurorae" "$TARGET/usr/share/"
        [ -d "$bundle/system-themes/Kvantum" ] && \
            cp -r "$bundle/system-themes/Kvantum" "$TARGET/usr/share/"
        [ -d "$bundle/system-themes/sddm-themes" ] && \
            cp -r "$bundle/system-themes/sddm-themes/." "$TARGET/usr/share/sddm/themes/"
        [ -d "$bundle/system-themes/fonts-system" ] && \
            cp -r "$bundle/system-themes/fonts-system/." "$TARGET/usr/share/fonts/"
        if [ -d "$bundle/system-themes/fonts-user" ]; then
            mkdir -p "$user_home/.local/share/fonts"
            cp -r "$bundle/system-themes/fonts-user/." "$user_home/.local/share/fonts/"
        fi
    fi

    if [ -d "$bundle/sddm" ]; then
        log "  Applying SDDM config"
        [ -f "$bundle/sddm/sddm.conf" ] && \
            cp "$bundle/sddm/sddm.conf" "$TARGET/etc/sddm.conf"
        [ -d "$bundle/sddm/sddm.conf.d" ] && \
            cp -r "$bundle/sddm/sddm.conf.d" "$TARGET/etc/"
    fi

    if [ -d "$bundle/wallpaper" ]; then
        log "  Applying wallpaper"
        mkdir -p "$user_home/.local/share/wallpapers"
        cp -r "$bundle/wallpaper/." "$user_home/.local/share/wallpapers/"
    fi

    arch-chroot "$TARGET" chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER"

    log "  Applying start icon"
    curl -fsSL "$START_ICON_URL" -o "$TARGET/etc/start.png" \
        || warn "start.png not found in repo (skipping)"

    rm -rf "$extract"
    log "Config applied."
}

# ── CLEANUP ───────────────────────────────────────────────────────────────────
INSTALL_OK=0
cleanup() {
    [ "$INSTALL_OK" = "1" ] && return 0
    log "Cleaning up mounts"
    umount -R "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT

# ── RUN ───────────────────────────────────────────────────────────────────────

# Enable multilib by uncommenting the existing section in pacman.conf
log "Enabling multilib repo"
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy >> "$LOG" 2>&1
# Copy the updated pacman.conf to new root so multilib stays enabled after install
# (pacstrap -K copies it during init, so we patch it after pacstrap finishes in do_chroot)

do_pacstrap
do_chroot
do_config

umount -R "$TARGET" 2>/dev/null || true
INSTALL_OK=1

log "=== LimeOS installation complete ==="
dialog --title "LimeOS Installer" --msgbox \
"Installation complete!

GRUB installed to $TARGET_DISK.
Windows and other OSes will appear in the boot menu.

Remove the installation media and reboot." 12 54

clear
echo -e "${GRN}${BLD}LimeOS installed. Reboot when ready.${RST}"
