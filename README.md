# Extraction
A simple tool that lets you capture and export an existing Linux installation into a portable, reusable form.

Extraction is built for people who want to take a system they’ve already set up  packages, configs, structure, everything and turn it into something they can move, duplicate, or restore anywhere. Instead of reinstalling and reconfiguring your environment from scratch, you can snapshot your current install and reuse it on new hardware, VMs, or fresh drives.

What it’s good for:

Migrating your setup to another machine

Backing up a fully configured system

Spinning up identical environments quickly

Experimenting without risking your main install

It keeps things simple. Run it, get a portable version of your system, and you’re free to use it however you want  no complicated steps, no rebuilding your environment from zero.

Guide
----------------------------------------------
 The tool has exactly **two things it does**:

| Command | What it's for |
|---|---|
| **`extract`** | Copy *this machine, right now* onto a drive |
| **`clone`** | Copy *any* Linux install — this one, or one sitting on another disk — onto a drive |

Both do the same thing under the hood (partition → copy everything →
fix up booting) — `extract` is just a shortcut for "clone the system
I'm currently running."

Works with any Arch install: BIOS or UEFI, GRUB or systemd-boot,
ext4/btrfs/xfs, and plain, encrypted (LUKS), or LVM setups.

---

## 1. Install what it needs

```bash
sudo pacman -S rsync parted dosfstools arch-install-scripts
```

If you plan to use btrfs or xfs on the target drive instead of the
default ext4, also install `btrfs-progs` or `xfsprogs`.

## 2. Plug in a USB drive (or identify a target disk)

Find its device name so you don't wipe the wrong thing:

```bash
sudo ./extraction+ list
```

This prints all your drives. Look for the one you just plugged in by
its size — it'll be something like `/dev/sdb`. **Use the whole-disk
name (`/dev/sdb`), not a partition (`/dev/sdb1`)** — the tool handles
partitioning for you.

## 3. Run it

**Easiest way — no arguments, just answer the prompts:**

```bash
sudo ./extraction+
```

It'll show you the menu:
Extract this install — clone the system you're running right now onto a drive
Clone a Linux install — copy an existing install (this one, or another disk) onto a different drive
q) Quit

Pick `1` to put your current machine on the USB. Pick `2` if you want
to clone some *other* install (e.g. an old internal drive) onto a new
disk.

**Or skip the menu and run it directly:**

```bash
# Put this machine on a USB:
sudo ./extraction+ extract /dev/sdb

# Clone a different install (e.g. an old drive) onto a new one:
sudo ./extraction+ clone /dev/sda2 /dev/sdb
```

Either way, it will:
1. Show you what's on the target disk and ask you to type `YES` to
   confirm wiping it.
2. Partition and format it.
3. Copy everything over — apps, settings, your whole `/home`, package
   database, AUR/Flatpak/Docker data. Not just a bare system.
4. Fix up the copy so it can actually boot on different hardware
   (broader driver support in the initramfs, bootloader reinstalled
   so it doesn't depend on this machine's boot menu entries).

When it's done, you can boot the drive on pretty much any machine by
picking it in that machine's boot menu (F12 / F2 / Del at startup,
depending on the computer).

## 4. Double-check before rebooting into it (optional but recommended)

```bash
sudo ./extraction+ verify /dev/sdb2   # or /dev/sdb1 if it's a single-partition (BIOS) drive
```

This mounts the drive read-only and checks that a kernel, a
bootloader, and a sane fstab are all present — without touching
anything.

---

## Good to know

- **Run this from a live/booted Linux environment** — an Arch ISO, or
  the machine you're extracting *from*. Never run it on a disk that's
  currently mounted as `/` for something *other* than the source.
- **It refuses to wipe the disk you're currently booted from.** No
  need to worry about accidentally destroying your own running system.
- **Encrypted (LUKS) or LVM installs**: your setup is preserved as-is
  — the tool only strips the one setting that would otherwise tie the
  copy to your exact current hardware. It'll also warn you if it sees
  LUKS or a RAID array, since their IDs are specific to the original
  disk and may need a manual update if you move to different physical
  media.
- **After moving to different hardware**, still worth checking by
  hand: NVIDIA/proprietary graphics drivers, and any VPN or network
  config tied to the old machine.

## Options, if you need them

These all go anywhere on the command line:

| Flag | Effect |
|---|---|
| `--dry-run` | Show exactly what would happen — nothing is touched |
| `--force` | Skip the "is there enough space" check |
| `--fs=btrfs` (or `xfs`) | Use that filesystem on the target instead of ext4 |
| `--bios` / `--uefi` | Force the partition style, instead of auto-detecting |
| `--keep-machine-id` | Don't reset the target's machine identity |

Example: `sudo ./extraction+ extract /dev/sdb --fs=btrfs --dry-run`

## Command reference

sudo extraction+ interactive menu
sudo extraction+ extract <target_disk> clone THIS machine onto target_disk
sudo extraction+ clone <source> <target_disk> clone an existing install onto target_disk
sudo extraction+ list show drives + this machine's boot mode
sudo extraction+ verify <root_partition> sanity-check a drive before booting it


For `clone`, `<source>` can be:
- `/` — this running system (same as `extract`)
- `/dev/sdXN` — a partition with a Linux install on it (mounted read-only for you automatically)
- a folder path — if you've already mounted something there yourself
