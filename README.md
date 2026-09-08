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
