# NixOS Install Guide

Step-by-step guide for installing (or re-installing) NixOS on a machine using disko for declarative disk partitioning and LUKS2 full-disk encryption.

> [!WARNING]
> Every disko step is **destructive** — it wipes and reformats the target disk. Double-check the device name before running anything.

> [!TIP]
> After cloning the repo, enter the NixOS install dev shell — it provides `just`, `git`, `age`, `sbctl`, `sops`, `nvim`, and all other tools needed for the install:
> ```bash
> nix develop .#nixos-install
> ```
> Most manual commands in Part 2 have a `just` shortcut available inside this shell. Run `just` to see all available recipes.

---

## Overview of what you'll end up with

```
/dev/nvme0n1  (GPT)
├── ESP  (1 MB → 1 GB)   vfat  →  /boot
└── root (1 GB → 100%)   LUKS2 (passphrase-protected)
                          └── btrfs
                              ├── /root  →  /
                              ├── /home  →  /home
                              ├── /nix   →  /nix
                              └── /log   →  /var/log
```

---

## Part 1 — Set up a new host in the repo

Skip this part if you are re-installing an existing host.

### 1.1 Create the host directory

```
hosts/<new-host>/
├── configuration.nix
└── disk-config.nix
```

### 1.2 Write `disk-config.nix`

`disk-config.nix` only needs the block device path. Everything else (partition layout, LUKS2 cipher/KDF args, btrfs subvolumes, mount options, kernel crypto modules) is provided by `modules/nixos/security/disk-encryption.nix`.

```nix
{ ... }: {
  security.diskEncryption.device = "/dev/nvme0n1";  # ← change this
}
```

Find the correct device name with `lsblk` on the target machine.

### 1.3 Register the host in `flake.nix`

```nix
nixosConfigurations = {
  lenovo-old = lib.mkNixosSystem "lenovo-old" "x86_64-linux";
  new-host   = lib.mkNixosSystem "new-host"   "x86_64-linux";
};
```

### 1.4 Write `configuration.nix`

See /hosts/lenovo-old/configuration.nix.

> Tip: check `dmesg | grep -E 'nvme|ahci|xhci'` on a live ISO to confirm which kernel modules your hardware needs.

### 1.5 Set the root password

The root password is stored as a SOPS secret, under `password-hash` in that host's own file. Hash a new password and save it before committing:

```bash
just set-password-hash lenovo-old
```

This asks for the password twice, hashes it with yescrypt and writes the hash straight into `secrets/hosts/lenovo-old.yaml` under `password-hash`. The password and the hash never reach the screen, so there is nothing in scroll-back and nothing to paste.

### 1.6 Commit and push

Push the new host config before you boot into the live ISO — you'll clone it from there.

---

## Part 2 — Install on the machine

### 2.1 Boot a NixOS live ISO

Download from https://nixos.org/download and write it to a USB drive. Boot the target machine from it.

### 2.2 Identify the target disk

```bash
lsblk
```

Confirm the device name (e.g. `/dev/nvme0n1`, `/dev/sda`). Make sure it matches what's in `disk-config.nix`. Once the repo is cloned (step 2.3), `just list-disks` is a cleaner alternative — it shows only whole disks with their size and model.

### 2.3 Clone the repo

```bash
nix-shell -p git --run "git clone <repo-url> /tmp/nixos-config"
cd /tmp/nixos-config
```

Then enter the install dev shell to get all required tools (`just`, `age`, `sbctl`, `sops`, etc.):

```bash
nix develop .#nixos-install
```

### 2.4 Partition, format, and mount (destructive)

```bash
sudo nix run github:nix-community/disko -- \
  --mode disko \
  --flake /tmp/nixos-config#<hostname>
```

The `--flake` flag is required. `disk-config.nix` only sets `security.diskEncryption.device` — the full disk layout lives in `modules/nixos/security/disk-encryption.nix` and is only reachable through the NixOS module system, which the flake evaluation provides.

This will:
1. Wipe and re-partition the disk (GPT).
2. Format the ESP as vfat.
3. Create the LUKS2 container — **you will be prompted for a passphrase. Choose a strong one and do not lose it.**
4. Format the inner volume as btrfs with subvolumes.
5. Mount everything under `/mnt`.

> [!TIP]
> `just disko <hostname>` runs the same command with less typing.

### 2.5 Set up the SOPS age key

The age key must exist on disk before `nixos-install` can activate any SOPS secrets. Do this now, while `/mnt` is mounted.

First, create the directory:

```bash
sudo mkdir -p /mnt/var/lib/sops-age
sudo chmod 700 /mnt/var/lib/sops-age
```

Then follow **one** of the two paths below depending on whether this is a new host or a reinstall.

---

#### Path A — New host (no existing key)

Generate a fresh key:

```bash
sudo nix-shell -p age --run "age-keygen -o /mnt/var/lib/sops-age/keys.txt"
sudo chmod 600 /mnt/var/lib/sops-age/keys.txt
```

Print the public key:

```bash
sudo grep 'public key' /mnt/var/lib/sops-age/keys.txt
```

**Save the entire `/mnt/var/lib/sops-age/keys.txt` file to BitWarden now** (secure note), before you do anything else. If the disk is ever wiped you will have no other copy.

You will also need the public key in step 2.10 to authorise this machine in `.sops.yaml`.

> [!TIP]
> `just generate-age-key` does all of the above and additionally pauses to remind you to save the key to BitWarden before clearing the screen.

---

#### Path B — Reinstall (key already exists in BitWarden)

Retrieve the `keys.txt` content from BitWarden and write it to disk. Do **not** use a file — write directly so the key never touches `/tmp` or shell history:

```bash
sudo mkdir -p /mnt/var/lib/sops-age/
sudo chmod 700 /mnt/var/lib/sops-age/
sudo nano /mnt/var/lib/sops-age/keys.txt
sudo chmod 600 /mnt/var/lib/sops-age/keys.txt
sudo grep 'public key' /mnt/var/lib/sops-age/keys.txt
```

No changes to `.sops.yaml` are needed — the key is the same one already authorised.

> [!TIP]
> `just restore-age-key` does all of the above. It prompts you to paste the full `keys.txt` content from BitWarden (via stdin / Ctrl+D), writes it with correct permissions, and validates that an `AGE-SECRET-KEY` line is present.

---

### 2.6 Create Secure Boot keys

lanzaboote needs the PKI bundle to exist before `nixos-install` can sign the boot files. Create the keys now while `/mnt` is still mounted.

> [!WARNING]
> The folder structure matters — lanzaboote expects keys inside a `keys/` subdirectory and also needs the `GUID` file in the parent. Getting this wrong causes a "Failed to read public key" error during install.

```bash
# 1. Generate keys in the default location
sudo nix-shell -p sbctl --run "sbctl create-keys"

# 2. Set up the exact folder structure lanzaboote expects on the target drive
sudo mkdir -p /mnt/etc/secureboot/keys
sudo chmod 700 /mnt/etc/secureboot
sudo cp -a /var/lib/sbctl/keys/* /mnt/etc/secureboot/keys/
sudo cp /var/lib/sbctl/GUID /mnt/etc/secureboot/

# 3. Mirror the keys to the live USB so nixos-install can sign the bootloader
#    (nixos-install runs in the live USB context and looks for keys at /etc/secureboot, not /mnt)
sudo mkdir -p /etc/secureboot
sudo cp -a /mnt/etc/secureboot/* /etc/secureboot/
```

> [!TIP]
> `just setup-secure-boot` runs all three steps above in one go.

### 2.7 Install NixOS

```bash
sudo nixos-install --flake /tmp/nixos-config#<hostname> --no-root-passwd
```

This builds the system closure, copies it into `/mnt/nix/store`, and writes the lanzaboote-signed bootloader.

> [!TIP]
> `just nixos-install <hostname>` runs the same command.

### 2.8 Reboot

```bash
sudo reboot
```

Remove the USB drive. The machine will boot into NixOS and prompt for the LUKS passphrase.

### 2.9 Enroll Secure Boot keys

> [!IMPORTANT]
> **Prerequisite — put the firmware into Setup Mode first.**
> Boot into your UEFI/BIOS settings and find the Secure Boot section. Clear the factory OEM keys — the option is usually labelled "Clear Secure Boot Keys", "Delete All Variables", or "Restore Factory Keys → Clear". This puts the firmware into **Setup Mode**, which is required before you can enroll your own keys. Without this step `sbctl enroll-keys` will fail with a "system is not in Setup Mode" error.

After logging in, enroll the keys into the UEFI firmware:

```bash
# Suppress the old-location migration warning (lanzaboote keeps keys in /etc/secureboot, not sbctl's default)
sudo sbctl setup --migrate

# Enroll your custom keys alongside Microsoft's hardware certificates
sudo sbctl enroll-keys --microsoft
```

The `--microsoft` flag includes Microsoft's certificates, which are required by most firmware to boot option ROMs and external devices.

Then reboot and **enable Secure Boot** in the UEFI firmware settings (usually F2/DEL/F12 during POST). From this point on the firmware will reject any unsigned or tampered bootloader, kernel, or initrd.

### 2.10 Authorise the new age key in SOPS

After the machine is up, follow **`docs/SOPS.md` → "Adding a new machine (new age key)"** to add the public key to `.sops.yaml`, re-encrypt secrets, commit, and push.

Then on the machine:

```bash
sudo nixos-rebuild switch --flake /path/to/repo#<hostname>
```

---

## Part 3 — Re-installing an existing host (destructive wipe)

Re-installing is identical to Part 2. There is nothing special to do in the repo — the host config already exists.

In step 2.5 use **Path B** (restore from BitWarden). The key stays the same, so `.sops.yaml` does not need updating and step 2.8 can be skipped.

> [!TIP]
> For a reinstall, steps 2.4 → 2.5 (Path B) → 2.6 → 2.7 can be collapsed into a single command:
> ```bash
> just install <hostname>
> ```
> This runs `disko`, `restore-age-key`, `setup-secure-boot`, and `nixos-install` in sequence. For a **new host** (Path A), run the steps individually: `just disko <hostname>`, then `just generate-age-key` (requires `/mnt` to be mounted), then `just setup-secure-boot`, then `just nixos-install <hostname>`.

---

## Mounting without reformatting

If you need to mount an already-formatted disk (e.g. you rebooted into a live ISO mid-install), use `--mode mount` instead of `--mode disko`:

```bash
sudo nix run github:nix-community/disko -- \
  --mode mount \
  --flake /tmp/nixos-config#<hostname>
```

This opens the LUKS container and mounts all btrfs subvolumes under `/mnt` without touching the partition table or formatting anything.

---

## LUKS passphrase

The LUKS passphrase is the **only** credential protecting the encrypted volume. There is no recovery key, no keyfile, and no escrow. If the passphrase is lost the data is unrecoverable.

The initrd prompts for it on every boot before the root filesystem is mounted.
