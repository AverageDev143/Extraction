#!/usr/bin/env bash
#
# extraction  —  Arch Linux extraction & cloning tool
#
# Two things it does:
#   1) EXTRACT — take the system you're running right now and put a
#      bootable copy of it on a USB drive (or any other disk).
#   2) CLONE   — copy an existing Linux install (this one, or one on
#      another disk) onto a different drive, and make that copy boot.
#
# Works with any Arch install: BIOS or UEFI, GRUB or systemd-boot,
# ext4/btrfs/xfs, plain or encrypted (LUKS)/LVM.
#
# Usage:
#   sudo ./extraction.sh                                    (interactive menu)
#   sudo ./extraction.sh extract <target_disk>              e.g. /dev/sdb
#   sudo ./extraction.sh clone   <source> <target_disk>     e.g. /dev/sda2 /dev/sdb
#   sudo ./extraction.sh list
#   sudo ./extraction.sh verify  <root_partition>
#
# <source> for 'clone' can be:
#   /            — the system you're currently running (same as 'extract')
#   /dev/sdXN    — a partition containing a Linux install (mounted read-only for you)
#   /some/path   — a directory you've already mounted yourself
#
# Flags (work anywhere on the command line):
#   --dry-run             print what would happen, touch nothing
#   --force               skip the pre-copy free-space check
#   --fs=ext4|btrfs|xfs  filesystem for the target (default: ext4)
#   --bios / --uefi       force partition scheme for the target
#                         (default: auto-detected from THIS machine)
#   --keep-machine-id     don't reset /etc/machine-id on the target
#
set -euo pipefail

VERSION="3.1.0"
SELF="$(basename "$0")"
WORK="/mnt/extraction-work"
DRY_RUN=0
FORCE=0
TARGET_FS="ext4"
BOOT_MODE_OVERRIDE=""
KEEP_MACHINE_ID=0

# source-tracking globals, set by prepare_source()
SRC_LIVE=0
SRC_MOUNT=""
SRC_SELF_MOUNTED=0

# target-tracking globals, set by partition_and_format_target()
ROOT_PART=""
EFI_PART=""

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
c_red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

info() { c_blue   "==> $*"; }
ok()   { c_green  " ✓ $*"; }
warn() { c_yellow " ! $*"; }
die()  { c_red    " ✗ $*"; exit 1; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    local prompt="$1"
    local ans
    read -r -p "$(c_yellow "$prompt [type YES to continue]: ")" ans
    [[ "$ans" == "YES" ]] || die "Aborted by user."
}

require_root() {
    [[ $EUID -eq 0 ]] || die "$SELF must be run as root (sudo $SELF ...)."
}

require_bin() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Required tool '$1' not found. Install it with: pacman -S $2"
}

# ---------------------------------------------------------------------------
# safety: never let us touch the disk the running system boots from
#
# FIX: the original used `lsblk ... || basename "$target"` which only
# fires the fallback when lsblk *exits non-zero*.  When the target is a
# whole-disk device (e.g. /dev/sdb), lsblk succeeds but prints nothing —
# so the fallback never ran and tdisk became "/dev/", defeating the check.
# Now we test -n on the output explicitly, matching parent_disk_of() below.
# ---------------------------------------------------------------------------
root_disk() {
    local src pk
    src="$(findmnt -no SOURCE /)" || true
    if [[ -z "$src" ]]; then
        echo ""
        return
    fi
    # For LVM/DM roots (e.g. /dev/mapper/vg-root) lsblk may not resolve a
    # PKNAME at all — return empty so the guard degrades to a no-op rather
    # than a false positive.
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
    [[ -n "$pk" ]] && echo "/dev/$pk" || echo ""
}

parent_disk_of() {
    local part="$1" pk
    pk="$(lsblk -no PKNAME "$part" 2>/dev/null || true)"
    [[ -n "$pk" ]] && echo "/dev/$pk" || echo ""
}

guard_not_root_disk() {
    local target="$1"
    local pk tdisk rdisk

    # Resolve the parent disk of the target (empty if target IS a whole disk)
    pk="$(lsblk -no PKNAME "$target" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then
        tdisk="/dev/$pk"
    else
        # target is itself a whole disk
        tdisk="$target"
    fi

    rdisk="$(root_disk)"

    if [[ -n "$rdisk" && "$tdisk" == "$rdisk" ]]; then
        die "$target is on $tdisk, which is the disk your running system boots from. Refusing to touch it."
    fi
}

# ---------------------------------------------------------------------------
# boot mode detection
# ---------------------------------------------------------------------------
detect_boot_mode() {
    [[ -d /sys/firmware/efi/efivars ]] && echo uefi || echo bios
}

effective_boot_mode() {
    [[ -n "$BOOT_MODE_OVERRIDE" ]] && echo "$BOOT_MODE_OVERRIDE" || detect_boot_mode
}

# ---------------------------------------------------------------------------
# figure out where a system expects its ESP mounted.
# reads the source fstab when available, then checks common paths.
# ---------------------------------------------------------------------------
get_esp_mountpoint() {
    local root="$1"   # "" for the live system, or a mounted path
    local fstab="$root/etc/fstab"
    local mp=""

    if [[ -f "$fstab" ]]; then
        mp="$(awk '$1 !~ /^#/ && $3 == "vfat" { print $2; exit }' "$fstab" 2>/dev/null || true)"
    fi

    if [[ -z "$mp" ]]; then
        local cand
        for cand in /efi /boot/efi /boot; do
            [[ -d "$root$cand" ]] && { mp="$cand"; break; }
        done
    fi

    [[ -z "$mp" ]] && mp="/boot/efi"
    echo "$mp"
}

# ---------------------------------------------------------------------------
# rsync exclude list — pseudo-filesystems, caches, swap, and our own work dir
# ---------------------------------------------------------------------------
RSYNC_EXCLUDES=(
    "/dev/*"
    "/proc/*"
    "/sys/*"
    "/tmp/*"
    "/run/*"
    "/mnt/*"
    "/media/*"
    "/lost+found"
    "/var/tmp/*"
    "/var/cache/pacman/pkg/*"
    "/swapfile"
    "/swap.img"
    "$WORK/*"
    "${WORK}-src/*"
)

build_rsync_excludes() {
    local e
    for e in "${RSYNC_EXCLUDES[@]}"; do
        printf '%s\n' "--exclude=$e"
    done
}

# ---------------------------------------------------------------------------
# space check — warn/abort if the target almost certainly won't fit
# ---------------------------------------------------------------------------
estimate_used_kb() {
    local under="$1"
    df --output=target,fstype,used -k 2>/dev/null | tail -n +2 | \
    awk -v root="$under" '
        $2 ~ /^(tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs|devpts|autofs|mqueue|efivarfs|debugfs|tracefs)$/ { next }
        {
            mp = $1; used = $3
            if (mp == root || index(mp, root "/") == 1) sum += used
        }
        END { print sum+0 }
    '
}

check_space_or_die() {
    local source_path="$1" target_mp="$2"
    local src_kb tgt_avail_kb needed_kb

    src_kb="$(estimate_used_kb "$source_path")"
    tgt_avail_kb="$(df --output=avail -k "$target_mp" 2>/dev/null | tail -1 | tr -d '[:space:]')"
    needed_kb=$(( src_kb + src_kb / 10 ))   # source + 10% headroom

    info "Source data (excluding pseudo-fs): ~$(( src_kb       / 1024 / 1024 )) GiB"
    info "Target free space:                 ~$(( tgt_avail_kb / 1024 / 1024 )) GiB"

    if [[ -z "$tgt_avail_kb" ]]; then
        warn "Could not determine free space on target — proceeding anyway."
        return
    fi

    if (( tgt_avail_kb < needed_kb )); then
        if [[ "$FORCE" == "1" ]]; then
            warn "Target may not have enough space, continuing anyway (--force given)."
        else
            die "Not enough space on target (need ~$(( needed_kb     / 1024 / 1024 )) GiB incl. 10% headroom, \
have ~$(( tgt_avail_kb / 1024 / 1024 )) GiB). Use a bigger drive or pass --force to skip this check."
        fi
    else
        ok "Enough space on target for the full clone."
    fi
}

# ---------------------------------------------------------------------------
# source handling — shared by 'extract' and 'clone'
# ---------------------------------------------------------------------------
prepare_source() {
    local arg="$1"
    SRC_LIVE=0; SRC_MOUNT=""; SRC_SELF_MOUNTED=0

    if [[ "$arg" == "/" ]]; then
        SRC_LIVE=1
    elif [[ -b "$arg" ]]; then
        SRC_MOUNT="${WORK}-src"
        mkdir -p "$SRC_MOUNT"
        info "Mounting source $arg -> $SRC_MOUNT (read-only)"
        run mount -o ro "$arg" "$SRC_MOUNT"
        SRC_SELF_MOUNTED=1
    elif [[ -d "$arg" ]]; then
        SRC_MOUNT="$arg"
    else
        die "Source '$arg' is not '/', a block device, or an existing directory."
    fi
}

cleanup_source() {
    if [[ "$SRC_SELF_MOUNTED" -eq 1 && -n "$SRC_MOUNT" ]]; then
        info "Unmounting source"
        run umount -R "$SRC_MOUNT" || true
    fi
}

source_rsync_path() {
    [[ "$SRC_LIVE" -eq 1 ]] && echo "/" || echo "$SRC_MOUNT/"
}

source_fstab_root() {
    [[ "$SRC_LIVE" -eq 1 ]] && echo "" || echo "$SRC_MOUNT"
}

# ---------------------------------------------------------------------------
# target: wipe, partition, format
# ---------------------------------------------------------------------------
partition_and_format_target() {
    local dev="$1"
    require_bin parted parted
    require_bin mkfs.vfat dosfstools

    local fs="$TARGET_FS"
    local -A fs_pkg=( [ext4]="e2fsprogs" [btrfs]="btrfs-progs" [xfs]="xfsprogs" )
    [[ -n "${fs_pkg[$fs]:-}" ]] || die "Unsupported --fs=$fs  (choose ext4, btrfs, or xfs)."
    require_bin "mkfs.$fs" "${fs_pkg[$fs]}"

    local boot_mode
    boot_mode="$(effective_boot_mode)"

    c_red   "THIS WILL ERASE ALL DATA ON $dev"
    lsblk "$dev"
    info "Partition scheme: $boot_mode   Filesystem: $fs"
    confirm "Confirm you want to wipe and partition $dev"

    EFI_PART=""; ROOT_PART=""

    if [[ "$boot_mode" == "uefi" ]]; then
        info "Creating GPT partition table on $dev"
        run parted -s "$dev" mklabel gpt
        info "Creating 1 GiB EFI system partition"
        run parted -s "$dev" mkpart ESP fat32 1MiB 1025MiB
        run parted -s "$dev" set 1 esp on
        info "Creating root partition (rest of disk, $fs)"
        run parted -s "$dev" mkpart primary 1025MiB 100%
        run partprobe "$dev"
        sleep 2

        # NVMe and MMC devices end in a digit, so partitions are p1/p2
        if [[ "$dev" =~ [0-9]$ ]]; then
            EFI_PART="${dev}p1"; ROOT_PART="${dev}p2"
        else
            EFI_PART="${dev}1";  ROOT_PART="${dev}2"
        fi

        info "Formatting $EFI_PART as FAT32 (label EXTRACT_EFI)"
        run mkfs.vfat -F32 -n EXTRACT_EFI "$EFI_PART"

    else   # bios / msdos
        info "Creating MBR (msdos) partition table on $dev"
        run parted -s "$dev" mklabel msdos
        info "Creating root partition (whole disk, $fs)"
        run parted -s "$dev" mkpart primary 1MiB 100%
        run parted -s "$dev" set 1 boot on
        run partprobe "$dev"
        sleep 2

        if [[ "$dev" =~ [0-9]$ ]]; then
            ROOT_PART="${dev}p1"
        else
            ROOT_PART="${dev}1"
        fi
    fi

    info "Formatting $ROOT_PART as $fs (label EXTRACT_ROOT)"
    case "$fs" in
        ext4)  run mkfs.ext4  -F  -L EXTRACT_ROOT "$ROOT_PART" ;;
        btrfs) run mkfs.btrfs -f  -L EXTRACT_ROOT "$ROOT_PART" ;;
        xfs)   run mkfs.xfs   -f  -L EXTRACT_ROOT "$ROOT_PART" ;;
    esac

    ok "$dev prepared ($boot_mode, $fs)."
}

# ---------------------------------------------------------------------------
# make the freshly-copied system bootable on other hardware
# ---------------------------------------------------------------------------
apply_portability() {
    local mnt="$1" efi_part="$2" esp_mp="$3" root_part="$4"

    # --- mkinitcpio portability ---
    info "Widening mkinitcpio so the initramfs works on unknown hardware"
    if [[ $DRY_RUN -eq 0 ]]; then
        local mkconf="$mnt/etc/mkinitcpio.conf"
        if [[ -f "$mkconf" ]]; then
            cp "$mkconf" "$mkconf.extraction.bak"

            # MODULES: merge in a broad hardware set; keep whatever is already
            # there (dm-crypt, dm_mod, filesystem modules, etc. are preserved).
            local current_modules broad_modules merged_modules
            current_modules="$(grep -m1 '^MODULES=' "$mkconf" \
                | sed -E 's/^MODULES=\(([^)]*)\)/\1/' || true)"
            broad_modules="ahci nvme sd_mod sr_mod usb_storage uas \
xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd \
virtio virtio_pci virtio_blk virtio_scsi ext4 vfat btrfs xfs"
            merged_modules="$(printf '%s\n' $current_modules $broad_modules \
                | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
            sed -i "s/^MODULES=.*/MODULES=($merged_modules)/" "$mkconf"

            # HOOKS: only drop 'autodetect' (it narrows the image to this
            # machine's hardware). Everything else — encrypt, lvm2,
            # mdadm_udev, btrfs, systemd, sd-vconsole — is left alone.
            local current_hooks new_hooks h
            current_hooks="$(grep -m1 '^HOOKS=' "$mkconf" \
                | sed -E 's/^HOOKS=\(([^)]*)\)/\1/' || true)"
            new_hooks="$(printf '%s\n' $current_hooks \
                | grep -v '^autodetect$' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
            for h in base udev block filesystems fsck; do
                [[ " $new_hooks " == *" $h "* ]] || new_hooks="$new_hooks $h"
            done
            sed -i "s/^HOOKS=.*/HOOKS=($new_hooks)/" "$mkconf"

            info "Regenerating initramfs inside chroot"
            arch-chroot "$mnt" mkinitcpio -P

            # Warn about configs that bind to specific disk identities
            if grep -qE '^[[:space:]]*[^#[:space:]]' "$mnt/etc/crypttab" 2>/dev/null; then
                warn "This install uses /etc/crypttab (LUKS). Its UUIDs point at the ORIGINAL disk — if this clone moves to different physical media, update crypttab (and any cryptdevice=/rd.luks.uuid= kernel parameter) with the new UUIDs before it will boot."
            fi
            if [[ -f "$mnt/etc/mdadm.conf" ]] \
                && grep -q '^ARRAY' "$mnt/etc/mdadm.conf" 2>/dev/null; then
                warn "This install has an mdadm RAID array configured — it won't exist on other hardware unless recreated."
            fi
        else
            warn "No /etc/mkinitcpio.conf found in target — skipping initramfs portability tweaks."
        fi
    else
        echo "[dry-run] would widen MODULES, strip 'autodetect' from HOOKS, run mkinitcpio -P"
    fi

    # --- bootloader ---
    local is_uefi=0
    [[ -n "$efi_part" ]] && is_uefi=1
    info "Installing bootloader for a $([[ $is_uefi -eq 1 ]] && echo UEFI || echo BIOS) target"

    if [[ $DRY_RUN -eq 0 ]]; then
        if [[ $is_uefi -eq 1 ]]; then
            if arch-chroot "$mnt" command -v grub-install >/dev/null 2>&1; then
                arch-chroot "$mnt" grub-install \
                    --target=x86_64-efi \
                    --efi-directory="$esp_mp" \
                    --removable \
                    --recheck \
                    || warn "grub-install failed — ensure grub and efibootmgr are installed in the target."
                arch-chroot "$mnt" grub-mkconfig -o /boot/grub/grub.cfg \
                    || warn "grub-mkconfig failed."
            elif arch-chroot "$mnt" command -v bootctl >/dev/null 2>&1; then
                arch-chroot "$mnt" bootctl install \
                    || warn "bootctl install failed."
                # Copy to the removable fallback path so it boots on machines
                # that won't scan for NVRAM entries (common on cheaper hardware)
                local efi_src="$mnt$esp_mp/EFI/systemd/systemd-bootx64.efi"
                if [[ -f "$efi_src" ]]; then
                    mkdir -p "$mnt$esp_mp/EFI/BOOT"
                    cp "$efi_src" "$mnt$esp_mp/EFI/BOOT/BOOTX64.EFI" || true
                    ok "Copied systemd-boot to EFI\\BOOT\\BOOTX64.EFI (removable fallback)."
                fi
                warn "systemd-boot: also check /boot/loader/entries — kernel/initrd paths must match this disk's layout."
            else
                warn "No known bootloader (grub / systemd-boot) found in target. Install and configure one manually."
            fi
        else
            local parent
            parent="$(parent_disk_of "$root_part")"
            if [[ -z "$parent" ]]; then
                warn "Couldn't determine the parent disk of $root_part for BIOS grub-install."
            elif arch-chroot "$mnt" command -v grub-install >/dev/null 2>&1; then
                arch-chroot "$mnt" grub-install \
                    --target=i386-pc \
                    --recheck \
                    "$parent" \
                    || warn "grub-install failed — ensure grub is installed in the target."
                arch-chroot "$mnt" grub-mkconfig -o /boot/grub/grub.cfg \
                    || warn "grub-mkconfig failed."
            else
                warn "No GRUB found in target for BIOS boot. Install grub (pacman -S grub) inside the target and re-run, or install a bootloader manually."
            fi
        fi
    else
        echo "[dry-run] would install/reconfigure bootloader for $([[ $is_uefi -eq 1 ]] && echo "UEFI --removable" || echo "BIOS")"
    fi

    # --- fstab cleanup ---
    info "Removing any stale swapfile entries from fstab"
    run sed -i '/\/swapfile/d;/\/swap\.img/d' "$mnt/etc/fstab" 2>/dev/null || true

    # --- machine identity ---
    if [[ $KEEP_MACHINE_ID -eq 0 ]]; then
        info "Resetting /etc/machine-id (will regenerate on first boot; pass --keep-machine-id to skip)"
        run rm -f "$mnt/etc/machine-id"
    fi
}

# ---------------------------------------------------------------------------
# shared copy flow — used by both 'extract' and 'clone'
# ---------------------------------------------------------------------------
do_transfer() {
    local target_disk="$1"
    require_bin rsync      rsync
    require_bin genfstab   arch-install-scripts
    require_bin arch-chroot arch-install-scripts

    [[ -b "$target_disk" ]] || die "$target_disk is not a block device."
    guard_not_root_disk "$target_disk"

    partition_and_format_target "$target_disk"

    mkdir -p "$WORK"
    info "Mounting $ROOT_PART at $WORK"
    run mount "$ROOT_PART" "$WORK"

    local esp_mp=""
    if [[ -n "$EFI_PART" ]]; then
        esp_mp="$(get_esp_mountpoint "$(source_fstab_root)")"
        mkdir -p "$WORK$esp_mp"
        info "Mounting $EFI_PART at $WORK$esp_mp"
        run mount "$EFI_PART" "$WORK$esp_mp"
    fi

    local src_path_for_space
    src_path_for_space="$([[ $SRC_LIVE -eq 1 ]] && echo "/" || echo "$SRC_MOUNT")"
    check_space_or_die "$src_path_for_space" "$WORK"

    info "Copying the install to $ROOT_PART via rsync"
    info "(installed apps, package DB, configs, all of /home, AUR/Flatpak/Docker data, etc.)"
    mapfile -t excl < <(build_rsync_excludes)
    run rsync -aAXH --info=progress2 "${excl[@]}" "$(source_rsync_path)" "$WORK/"

    info "Generating UUID-based fstab for the target"
    if [[ $DRY_RUN -eq 0 ]]; then
        genfstab -U "$WORK" > "$WORK/etc/fstab"
    else
        echo "[dry-run] genfstab -U $WORK > $WORK/etc/fstab"
    fi

    apply_portability "$WORK" "$EFI_PART" "$esp_mp" "$ROOT_PART"

    info "Unmounting target"
    run umount -R "$WORK" || true

    ok "Done — $target_disk now has a bootable copy of the install."
    info "Boot it on other hardware by picking it in the firmware/BIOS boot menu (F12 / F2 / Del at startup)."
}

# ---------------------------------------------------------------------------
# the two main commands
# ---------------------------------------------------------------------------
cmd_extract() {
    local target_disk="${1:?Usage: $SELF extract <target_disk>   e.g. /dev/sdb}"
    require_root
    SRC_LIVE=1; SRC_MOUNT=""; SRC_SELF_MOUNTED=0
    do_transfer "$target_disk"
}

cmd_clone() {
    local source="${1:?Usage: $SELF clone <source> <target_disk>}"
    local target_disk="${2:?Usage: $SELF clone <source> <target_disk>}"
    require_root
    prepare_source "$source"
    do_transfer "$target_disk"
    cleanup_source
}

# ---------------------------------------------------------------------------
# utility commands
# ---------------------------------------------------------------------------
cmd_list() {
    info "Block devices on this machine:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
    echo
    info "Running system's root device:"
    findmnt -no SOURCE,FSTYPE /
    info "Boot mode detected: $(detect_boot_mode)"
}

cmd_verify() {
    local root_part="${1:?Usage: $SELF verify <root_partition>}"
    require_root
    mkdir -p "$WORK"
    run mount -o ro "$root_part" "$WORK"

    info "Sanity checks on $root_part"

    local f
    for f in etc/fstab etc/passwd etc/os-release; do
        if [[ -e "$WORK/$f" ]]; then
            ok "found /$f"
        else
            warn "missing /$f"
        fi
    done

    if compgen -G "$WORK/boot/vmlinuz-*" >/dev/null 2>&1; then
        ok "kernel(s): $(basename -a "$WORK"/boot/vmlinuz-* | tr '\n' ' ')"
    else
        warn "no /boot/vmlinuz-* kernel found"
    fi

    [[ -d "$WORK/boot/grub" ]]            && ok "GRUB config present"
    [[ -d "$WORK/boot/loader/entries" ]]  && ok "systemd-boot entries present"

    local fstype
    fstype="$(findmnt -no FSTYPE "$WORK" 2>/dev/null || echo unknown)"
    info "Root filesystem type: $fstype"
    info "ESP mountpoint (from fstab): $(get_esp_mountpoint "$WORK")"

    if grep -qE '^[[:space:]]*[^#[:space:]]' "$WORK/etc/crypttab" 2>/dev/null; then
        warn "crypttab has active entries — disk UUIDs are hardware-specific. Verify before moving to new hardware."
    fi

    echo
    info "fstab contents:"
    cat "$WORK/etc/fstab" 2>/dev/null || warn "no fstab found"

    run umount -R "$WORK" || true
}

# ---------------------------------------------------------------------------
# interactive menu — runs when no subcommand is given
# ---------------------------------------------------------------------------
interactive_menu() {
    echo "extraction v$VERSION"
    echo
    info "Current block devices (for reference):"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
    echo
    echo "What do you want to do?"
    echo "  1) Extract this install   — clone the system you're running right now onto a drive"
    echo "  2) Clone a Linux install  — copy an existing install (this one or another disk) onto a drive"
    echo "  q) Quit"
    local choice
    read -r -p "> " choice
    case "$choice" in
        1)
            local tgt
            read -r -p "Target device to write to (e.g. /dev/sdb — will be ERASED): " tgt
            cmd_extract "$tgt"
            ;;
        2)
            local src tgt
            read -r -p "Source ('/' for this running system, or a partition like /dev/sda2): " src
            read -r -p "Target device to write to (e.g. /dev/sdb — will be ERASED): " tgt
            cmd_clone "$src" "$tgt"
            ;;
        q|Q) exit 0 ;;
        *) die "Unrecognized choice '$choice'." ;;
    esac
}

# ---------------------------------------------------------------------------
# help text
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
extraction  v$VERSION  —  Arch Linux extraction & cloning tool

COMMANDS:
  (no args)                   interactive menu
  extract <target_disk>       clone THIS machine onto target_disk
  clone   <source> <target>   clone an existing install onto target_disk
  list                        show drives and this machine's boot mode
  verify  <root_partition>    sanity-check a drive before booting it

  <source> for 'clone':
    /              — this running system (same as extract)
    /dev/sdXN      — a partition with a Linux install on it
    /some/path     — a directory you've already mounted

FLAGS (go anywhere on the command line):
  --dry-run             show what would happen; touch nothing
  --force               skip the pre-copy free-space check
  --fs=ext4|btrfs|xfs  filesystem for the target (default: ext4)
  --bios / --uefi       force the partition scheme
  --keep-machine-id     don't reset /etc/machine-id on the target
  -h, --help            show this help
  -v, --version         show version

EXAMPLES:
  Put this machine on a USB you can boot elsewhere:
    sudo $SELF extract /dev/sdb

  Clone an old internal drive to a new one (booted from an Arch ISO):
    sudo $SELF clone /dev/sda2 /dev/nvme0n1

  Force BIOS-style partitioning even from a UEFI machine:
    sudo $SELF extract --bios /dev/sdb

  Use btrfs on the target instead of ext4:
    sudo $SELF clone / /dev/sdb --fs=btrfs

  Preview what would happen without touching anything:
    sudo $SELF extract /dev/sdb --dry-run

WHAT HAPPENS (same for extract & clone):
  1. Wipes and partitions the target disk (asks for YES confirmation).
  2. Copies everything — apps, package DB, configs, /home, AUR/Flatpak/Docker data.
  3. Regenerates the initramfs with broad hardware support (removes 'autodetect',
     preserves encrypt/lvm2/mdadm_udev/btrfs and any other hooks you have).
  4. Installs/reconfigures the bootloader using the --removable flag so it
     boots without depending on this machine's NVRAM entries.
  5. Regenerates fstab with UUIDs for the new partitions.
  6. Resets /etc/machine-id so the clone gets a fresh identity on first boot.

NOTES:
  - Run as root from any live/booted Linux environment.
  - The tool refuses to wipe the disk your running system boots from.
  - LUKS/LVM installs: your encryption is preserved as-is. The tool will warn
    you that crypttab UUIDs are disk-specific and may need updating on new media.
  - After moving to new hardware, still worth checking manually: proprietary GPU
    drivers, and any VPN or network config tied to the old machine.

DEPENDENCIES (install with pacman):
  rsync parted dosfstools arch-install-scripts
  + btrfs-progs or xfsprogs if using --fs=btrfs / --fs=xfs
EOF
}

# ---------------------------------------------------------------------------
# argument parsing — flags can appear anywhere on the command line
# ---------------------------------------------------------------------------
ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run)        DRY_RUN=1 ;;
        --force)          FORCE=1 ;;
        --fs=*)           TARGET_FS="${a#*=}" ;;
        --bios)           BOOT_MODE_OVERRIDE="bios" ;;
        --uefi)           BOOT_MODE_OVERRIDE="uefi" ;;
        --keep-machine-id) KEEP_MACHINE_ID=1 ;;
        -h|--help)        usage; exit 0 ;;
        -v|--version)     echo "$SELF $VERSION"; exit 0 ;;
        *)                ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]:-}"

cmd="${1:-}"
[[ -n "$cmd" ]] && shift || true

case "$cmd" in
    extract) cmd_extract "$@" ;;
    clone)   cmd_clone   "$@" ;;
    list)    cmd_list    "$@" ;;
    verify)  cmd_verify  "$@" ;;
    help)    usage ;;
    "")      require_root; interactive_menu ;;
    *)       die "Unknown command '$cmd'. Run '$SELF --help'." ;;
esac
