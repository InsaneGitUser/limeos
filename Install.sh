#!/bin/bash
set -e

REPO="https://raw.githubusercontent.com/InsaneGitUser/My-Shit/refs/heads/main"
PACKAGES_URL="$REPO/packages.txt"
CONFIG_URL="https://github.com/InsaneGitUser/My-Shit/raw/main/config.tar.gz"
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
# dialog is not included in the Arch live ISO by default
if ! command -v dialog >/dev/null 2>&1; then
    echo -e "${BLD}Installing dialog...${RST}"
    pacman -Sy --noconfirm dialog >> "$LOG" 2>&1 \
        || { echo -e "${RED}Failed to install dialog — check internet connection.${RST}"; exit 1; }
fi

# ── DEPENDENCY CHECK ──────────────────────────────────────────────────────────
for cmd in pacstrap arch-chroot parted mkfs.fat mkfs.ext4 blkid lsblk sgdisk dialog curl; do
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

# ── DISK/PARTITION PICKERS ────────────────────────────────────────────────────
pick_disk() {
    local -a args=()
    while IFS= read -r line; do
        local name size model
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        model=$(awk '{$1=$2=""; gsub(/^[[:space:]]+/,"",$0); print}' <<< "$line")
        args+=("/dev/$name" "$size ${model:-Unknown}")
    done < <(lsblk -dno NAME,SIZE,MODEL | grep -v '^loop\|^sr')
    [ ${#args[@]} -eq 0 ] && die "No disks found."
    dialog --stdout --title "LimeOS Installer" --menu "$1" 20 76 12 "${args[@]}"
}

pick_partition() {
    local filter="$1"
    local -a args=()
    while IFS= read -r line; do
        local name size fs label
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        fs=$(awk '{print $3}'   <<< "$line")
        label=$(awk '{print $4}' <<< "$line")
        local desc="$size"
        [ -n "$fs"    ] && desc="$desc [$fs]"
        [ -n "$label" ] && desc="$desc \"$label\""
        args+=("$name" "$desc")
    done < <(lsblk -pno NAME,SIZE,FSTYPE,LABEL,TYPE \
        | awk '$5=="part"' \
        | grep "^${filter}")
    [ ${#args[@]} -eq 0 ] && return 1
    dialog --stdout --title "LimeOS Installer" \
        --menu "Select partition to install onto:" 20 76 12 "${args[@]}"
}

# ── SCREEN: FIRMWARE ──────────────────────────────────────────────────────────
screen_firmware() {
    local det; det=$(detect_firmware)
    local d_uefi="off" d_bios="off"
    [ "$det" = "uefi" ] && d_uefi="on" || d_bios="on"
    FIRMWARE=$(dialog --stdout --title "LimeOS Installer" \
        --radiolist "Boot firmware (detected: ${det^^}):" 10 60 2 \
        "uefi" "UEFI — GPT + EFI System Partition" "$d_uefi" \
        "bios" "Legacy BIOS — MBR bootloader"      "$d_bios") \
        || die "Cancelled."
    log "Firmware: $FIRMWARE"
}

# ── SCREEN: INSTALL MODE ──────────────────────────────────────────────────────
screen_mode() {
    INSTALL_MODE=$(dialog --stdout --title "LimeOS Installer" \
        --radiolist "Installation mode:" 10 70 2 \
        "fulldisk"  "Full disk — erase entire disk"                        "off" \
        "partition" "Partition — install alongside existing OS (dual-boot)" "on") \
        || die "Cancelled."
    log "Mode: $INSTALL_MODE"
}

# ── SCREEN: DISK / PARTITION ──────────────────────────────────────────────────
screen_pick_target() {
    if [ "$INSTALL_MODE" = "fulldisk" ]; then
        TARGET_DISK=$(pick_disk "WARNING: entire disk will be ERASED:") \
            || die "Cancelled."
        dialog --title "LimeOS Installer" \
            --yesno "ERASE ALL DATA on $TARGET_DISK?\n\nThis cannot be undone." 8 50 \
            || die "Aborted."
    else
        local scope
        scope=$(pick_disk "Which disk contains your target partition?") \
            || die "Cancelled."
        TARGET_PART=$(pick_partition "$scope") || \
            TARGET_PART=$(pick_partition "") || \
            die "No partitions found. Create one first with cfdisk."
        TARGET_DISK=$(parent_disk "$TARGET_PART")
        dialog --title "LimeOS Installer" \
            --yesno "Format and install onto $TARGET_PART?\n\nOnly this partition will be touched." 8 58 \
            || die "Aborted."
    fi
    log "Target disk: ${TARGET_DISK}  partition: ${TARGET_PART:-will create}"
}

# ── SCREEN: ESP ───────────────────────────────────────────────────────────────
screen_esp() {
    [ "$FIRMWARE" != "uefi" ] && TARGET_ESP="" && return 0
    local existing
    existing=$(lsblk -pno NAME,PARTTYPE "$TARGET_DISK" 2>/dev/null \
        | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" \
        | awk '{print $1}' | head -1 || true)
    if [ -n "$existing" ]; then
        local esz; esz=$(lsblk -no SIZE "$existing" | head -1)
        local choice
        choice=$(dialog --stdout --title "LimeOS Installer" \
            --radiolist "EFI System Partition:" 10 72 2 \
            "reuse"  "Reuse $existing ($esz) — preserves Windows/other OS boot" "on" \
            "create" "Create new 512MB ESP — only if no other OS on this disk"  "off") \
            || die "Cancelled."
        [ "$choice" = "reuse" ] && TARGET_ESP="$existing" || TARGET_ESP=""
    else
        dialog --title "LimeOS Installer" --msgbox \
            "No ESP found on $TARGET_DISK.\nA new 512MB ESP will be created in free space." 8 58
        TARGET_ESP=""
    fi
    log "ESP: ${TARGET_ESP:-will create}"
}

# ── BIOS + GPT GUARD ──────────────────────────────────────────────────────────
check_bios_gpt() {
    [ "$FIRMWARE" != "bios" ]          && return 0
    [ "$INSTALL_MODE" != "partition" ] && return 0
    local pttype
    pttype=$(lsblk -no PTTYPE "$TARGET_DISK" 2>/dev/null | head -1 || true)
    [ "$pttype" != "gpt" ] && return 0
    local has_biosgrub
    has_biosgrub=$(lsblk -pno NAME,PARTTYPE "$TARGET_DISK" 2>/dev/null \
        | grep -i "21686148-6449-6e6f-744e-656564454649" || true)
    if [ -z "$has_biosgrub" ]; then
        dialog --title "BIOS + GPT Warning" --msgbox \
"$TARGET_DISK uses GPT but you selected Legacy BIOS.

GRUB needs a 1MiB BIOS boot partition on GPT disks.
None was found. Options:
  1. Switch to UEFI if your machine supports it
  2. Add a 1MiB BIOS boot partition with cgdisk first

Installer will continue but GRUB may fail." 14 58
        warn "BIOS on GPT without bios_grub partition"
    fi
}

# ── PARTITIONING ──────────────────────────────────────────────────────────────
do_partition() {
    if [ "$INSTALL_MODE" = "fulldisk" ]; then
        log "Wiping and partitioning $TARGET_DISK"
        dd if=/dev/zero of="$TARGET_DISK" bs=512 count=2048 2>/dev/null || true
        sync
        if [ "$FIRMWARE" = "uefi" ]; then
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
            mkfs.fat -F32 -n EFI "$TARGET_ESP"
        else
            parted -s "$TARGET_DISK" \
                mklabel msdos \
                mkpart primary ext4 1MiB 100% \
                set 1 boot on
            partprobe "$TARGET_DISK"; sleep 2
            TARGET_PART=$(lsblk -rno NAME "$TARGET_DISK" \
                | grep -v "^$(basename "$TARGET_DISK")$" \
                | awk 'NR==1{print "/dev/" $1}')
            [ -b "$TARGET_PART" ] || die "Root partition not found after partitioning"
            TARGET_ESP=""
        fi
    fi

    # UEFI dual-boot — create ESP if none exists
    if [ "$FIRMWARE" = "uefi" ] && [ -z "$TARGET_ESP" ]; then
        log "Creating 512MB ESP on $TARGET_DISK"
        local next
        next=$(sgdisk -p "$TARGET_DISK" 2>/dev/null \
            | awk '/^[[:space:]]+[0-9]/{n=$1} END{print n+0+1}')
        [ -z "$next" ] && next=2
        sgdisk -n "${next}:0:+512M" -t "${next}:EF00" -c "${next}:EFI" "$TARGET_DISK" \
            || die "sgdisk failed — not enough free space for 512MB ESP"
        partprobe "$TARGET_DISK"; sleep 2
        TARGET_ESP=$(lsblk -pno NAME,PARTTYPE "$TARGET_DISK" \
            | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" \
            | awk '{print $1}' | tail -1)
        [ -n "$TARGET_ESP" ] || die "ESP not found after creation"
        mkfs.fat -F32 -n EFI "$TARGET_ESP"
    fi

    log "Formatting $TARGET_PART as ext4"
    mkfs.ext4 -F -L "LimeOS" "$TARGET_PART" || die "mkfs.ext4 failed"
    log "Partitioning done: ROOT=$TARGET_PART ESP=${TARGET_ESP:-none}"
}

# ── MOUNT ─────────────────────────────────────────────────────────────────────
do_mount() {
    log "Mounting filesystems"
    mount "$TARGET_PART" "$TARGET"
    if [ "$FIRMWARE" = "uefi" ] && [ -n "$TARGET_ESP" ]; then
        mkdir -p "$TARGET/boot/efi"
        mount "$TARGET_ESP" "$TARGET/boot/efi"
        log "ESP mounted at $TARGET/boot/efi"
    fi
}

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

    pacstrap -K "$TARGET" \
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

    # fstab
    genfstab -U "$TARGET" >> "$TARGET/etc/fstab"

    # Timezone
    arch-chroot "$TARGET" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    arch-chroot "$TARGET" hwclock --systohc

    # Locale
    echo "en_US.UTF-8 UTF-8" >> "$TARGET/etc/locale.gen"
    arch-chroot "$TARGET" locale-gen >> "$LOG" 2>&1
    echo "LANG=en_US.UTF-8" > "$TARGET/etc/locale.conf"

    # Hostname
    echo "$HOSTNAME" > "$TARGET/etc/hostname"
    cat > "$TARGET/etc/hosts" <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

    # Services
    for svc in "${SERVICES[@]}"; do
        arch-chroot "$TARGET" systemctl enable "$svc" >> "$LOG" 2>&1 \
            && log "  Enabled $svc" \
            || warn "  Could not enable $svc (package may not be installed)"
    done

    # Root password
    echo ""
    echo -e "${BLD}Set password for root:${RST}"
    arch-chroot "$TARGET" passwd

    # User lime
    log "Creating user: $NEW_USER"
    arch-chroot "$TARGET" useradd -m \
        -G wheel,audio,video,storage,optical,input \
        -s /bin/bash "$NEW_USER"
    echo ""
    echo -e "${BLD}Set password for $NEW_USER:${RST}"
    arch-chroot "$TARGET" passwd "$NEW_USER"

    # sudo for wheel
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        "$TARGET/etc/sudoers"

    # GRUB
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

    # os-prober so Windows shows up in GRUB
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
    tar -xzf "$tarball" -C "$extract" \
        || die "Failed to extract config.tar.gz"
    rm -f "$tarball"

    # The tar contains: config/ local-share/ system-themes/ sddm/ wallpaper/
    local bundle
    # Handle whether tar extracted with or without a top-level folder
    if [ -d "$extract/limeos-config" ]; then
        bundle="$extract/limeos-config"
    else
        bundle="$extract"
    fi

    local user_home="$TARGET/home/$NEW_USER"

    # ~/.config — KDE/Plasma config files
    if [ -d "$bundle/config" ]; then
        log "  Applying ~/.config"
        mkdir -p "$user_home/.config"
        cp -r "$bundle/config/." "$user_home/.config/"
    fi

    # ~/.local/share — Plasma addons, konsole profiles, color schemes etc
    if [ -d "$bundle/local-share" ]; then
        log "  Applying ~/.local/share"
        mkdir -p "$user_home/.local/share"
        cp -r "$bundle/local-share/." "$user_home/.local/share/"
    fi

    # System-wide themes — icons, fonts, cursor, GTK, Plasma, Kvantum, SDDM
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
        # Fonts
        if [ -d "$bundle/system-themes/fonts-system" ]; then
            cp -r "$bundle/system-themes/fonts-system/." "$TARGET/usr/share/fonts/"
        fi
        if [ -d "$bundle/system-themes/fonts-user" ]; then
            mkdir -p "$user_home/.local/share/fonts"
            cp -r "$bundle/system-themes/fonts-user/." "$user_home/.local/share/fonts/"
        fi
    fi

    # SDDM config
    if [ -d "$bundle/sddm" ]; then
        log "  Applying SDDM config"
        [ -f "$bundle/sddm/sddm.conf" ] && \
            cp "$bundle/sddm/sddm.conf" "$TARGET/etc/sddm.conf"
        [ -d "$bundle/sddm/sddm.conf.d" ] && \
            cp -r "$bundle/sddm/sddm.conf.d" "$TARGET/etc/"
    fi

    # Wallpaper — copy into user home
    if [ -d "$bundle/wallpaper" ]; then
        log "  Applying wallpaper"
        mkdir -p "$user_home/.local/share/wallpapers"
        cp -r "$bundle/wallpaper/." "$user_home/.local/share/wallpapers/"
    fi

    # Fix ownership of everything in user home
    arch-chroot "$TARGET" chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER"

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

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    log "=== LimeOS installer start ==="

    screen_firmware
    screen_mode
    screen_pick_target
    screen_esp
    check_bios_gpt

    HOSTNAME=$(dialog --stdout --title "LimeOS Installer" \
        --inputbox "Enter a hostname for this machine:" 8 50) \
        || die "Cancelled."
    [ -z "$HOSTNAME" ] && HOSTNAME="limeos"

    local esp_display="${TARGET_ESP:-none}"
    [ "$FIRMWARE" = "bios" ] && esp_display="N/A"

    dialog --title "LimeOS Installer" --yesno \
"Ready to install. Summary:

  Firmware:  $FIRMWARE
  Mode:      $INSTALL_MODE
  Disk:      $TARGET_DISK
  Root:      ${TARGET_PART:-will create}
  ESP:       $esp_display
  Hostname:  $HOSTNAME
  User:      $NEW_USER

Proceed?" 18 52 || die "Aborted."

    do_partition
    do_mount
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
}

main "$@"
