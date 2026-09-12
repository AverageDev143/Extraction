# Extraction

A tool that captures your existing Linux installation and puts it onto another drive — fully bootable, with everything intact.

Extraction is for people who want to take a system they've already set up — packages, configs, dotfiles, all of `/home` — and move it somewhere else without starting from scratch. Run it, get a bootable copy, use it however you want.

**What it's good for:**
- Migrating your setup to a new machine
- Keeping a fully configured system as a backup
- Spinning up identical environments on different hardware
- Experimenting on a USB without touching your main install

---

## How it works

The tool has exactly two commands:

| Command | What it does |
|---|---|
| `extract` | Copy **this machine, right now** onto a drive |
| `clone` | Copy **any** Linux install — this one, or one on another disk — onto a drive |

Both do the same thing under the hood (partition → copy everything → fix up booting). `extract` is just a shortcut for "clone the system I'm currently running."

Works with any Arch install: BIOS or UEFI, GRUB or systemd-boot, ext4/btrfs/xfs, and plain, encrypted (LUKS), or LVM setups.

---

## Quickstart

### 1. Install dependencies

```bash
sudo pacman -S rsync parted dosfstools arch-install-scripts
```

If you want to use btrfs or xfs on the target drive instead of the default ext4, also install `btrfs-progs` or `xfsprogs`.

### 2. Find your target drive

Plug in a USB drive (or identify which disk you want to write to), then run:

```bash
sudo ./extraction.sh list
```

This prints every block device on the machine — name, size, filesystem, label, mount point, and model — plus your running system's root device and detected boot mode. Find your target by size.

> **Use the whole-disk name (`/dev/sdb`), not a partition (`/dev/sdb1`).** The tool handles partitioning for you.

### 3. Run it

**Easiest — no arguments, just answer the prompts:**

```bash
sudo ./extraction.sh
```

You'll see:

```
1) Extract this install   — clone the system you're running right now onto a drive
2) Clone a Linux install  — copy an existing install (this one or another disk) onto a drive
q) Quit
```

Pick `1` to clone your current machine. Pick `2` to clone a different install — it'll ask for the source partition (e.g. `/dev/sda2`) and the target disk.

**Or run it directly, skipping the menu:**

```bash
# Clone this machine onto a USB:
sudo ./extraction.sh extract /dev/sdb

# Clone a different install onto a new disk:
sudo ./extraction.sh clone /dev/sda2 /dev/sdb
```

Either way, the tool will:

1. Show what's on the target disk and ask you to type `YES` to confirm wiping it
2. Wipe and partition the disk (GPT + EFI partition for UEFI, MBR for BIOS)
3. Format the partitions (ext4 by default, or whatever you pass with `--fs`)
4. Check you have enough space on the target before starting the copy
5. Copy everything over via rsync — installed apps, package database, configs, all of `/home`, AUR/Flatpak/Docker data
6. Generate a fresh UUID-based fstab for the new partitions
7. Widen the initramfs: adds broad storage/USB/driver modules and removes the `autodetect` hook that would tie it to this machine's hardware — your existing hooks (`encrypt`, `lvm2`, `mdadm_udev`, etc.) are left untouched
8. Reinstall the bootloader with `--removable` so it boots without depending on this machine's NVRAM entries
9. Remove stale swapfile entries from fstab
10. Reset `/etc/machine-id` so the clone gets a fresh identity on first boot

When it's done, you can boot the drive on pretty much any machine by picking it in the firmware boot menu (usually `F12`, `F2`, or `Del` at startup).

### 4. Verify before rebooting (optional but recommended)

```bash
# UEFI drive (two partitions — pass the root partition, not the EFI one):
sudo ./extraction.sh verify /dev/sdb2

# BIOS drive (single partition):
sudo ./extraction.sh verify /dev/sdb1
```

This mounts the partition read-only and checks:

- `/etc/fstab`, `/etc/passwd`, `/etc/os-release` are present
- At least one kernel (`/boot/vmlinuz-*`) exists
- A bootloader config is present (GRUB directory or systemd-boot entries)
- Warns if `/etc/crypttab` has active entries with disk-specific UUIDs
- Prints the detected filesystem type, ESP mountpoint, and full fstab contents

Nothing is written — it unmounts cleanly when done.

---

## Good to know

- **Run from a live environment or the machine you're extracting from.** An Arch ISO works fine. Never run it on a disk that's currently mounted as `/` for something other than the source.
- **It will never wipe the disk your running system boots from.** The tool resolves the parent disk of both the target and your running root and refuses if they match.
- **LUKS and LVM installs are preserved as-is.** The tool warns you if it detects an active `crypttab` or `mdadm.conf`, since those UUIDs are disk-specific and may need updating if you move to different physical media.
- **After moving to new hardware**, still worth checking manually: proprietary GPU drivers (NVIDIA especially), and any VPN or network config tied to the old machine's hardware addresses.

---

## Options

These flags work anywhere on the command line:

| Flag | Effect |
|---|---|
| `--dry-run` | Print exactly what would happen — nothing is written |
| `--force` | Skip the free-space check |
| `--fs=ext4` / `--fs=btrfs` / `--fs=xfs` | Filesystem for the target (default: ext4) |
| `--bios` / `--uefi` | Force the partition scheme instead of auto-detecting from this machine |
| `--keep-machine-id` | Don't reset `/etc/machine-id` on the target |
| `-v` / `--version` | Print the version and exit |

**Examples:**

```bash
# Preview what would happen without touching anything:
sudo ./extraction.sh extract /dev/sdb --dry-run

# Use btrfs on the target:
sudo ./extraction.sh extract /dev/sdb --fs=btrfs

# Force BIOS-style partitioning even from a UEFI machine:
sudo ./extraction.sh extract /dev/sdb --bios

# Combine flags — they go anywhere on the line:
sudo ./extraction.sh extract /dev/sdb --fs=btrfs --dry-run
```

---

## Command reference

```
sudo ./extraction.sh                              interactive menu
sudo ./extraction.sh extract <target_disk>        clone this machine onto target_disk
sudo ./extraction.sh clone <source> <target>      clone an existing install onto target
sudo ./extraction.sh list                         show drives and this machine's boot mode
sudo ./extraction.sh verify <root_partition>      sanity-check a drive before booting it
```

For `clone`, `<source>` can be:
- `/` — this running system (same as `extract`)
- `/dev/sdXN` — a partition with a Linux install on it (mounted read-only automatically)
- A folder path — if you've already mounted it yourself
