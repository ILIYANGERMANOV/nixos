# ─── Live ISO ────────────────────────────────────────────────────────────────
# Run these from /tmp/nixos-config on the NixOS live USB.

# List whole disks — copy PATH value into hosts/<hostname>/disk-config.nix
list-disks:
    @echo "Set security.diskEncryption.device to the PATH of the target disk:"
    @echo ""
    lsblk -d -o PATH,SIZE,MODEL

# Partition, format (LUKS2 + btrfs), and mount the target disk — DESTRUCTIVE
disko host:
    sudo nix run github:nix-community/disko -- \
        --mode disko \
        --flake .#{{host}}

# Restore an existing age private key from BitWarden onto /mnt.
# Paste the full keys.txt content in the terminal, then press Ctrl+D.
restore-age-key:
    sudo mkdir -p /mnt/var/lib/sops-age
    sudo chmod 700 /mnt/var/lib/sops-age
    echo ""
    echo "Paste the full keys.txt content from BitWarden, then press Ctrl+D:"
    echo ""
    sudo tee /mnt/var/lib/sops-age/keys.txt > /dev/null
    sudo chmod 600 /mnt/var/lib/sops-age/keys.txt
    sudo grep -q "AGE-SECRET-KEY" /mnt/var/lib/sops-age/keys.txt \
        || { echo "ERROR: no AGE-SECRET-KEY line found — check what you pasted"; exit 1; }
    echo ""
    echo "Key restored. Public key:"
    sudo grep "public key" /mnt/var/lib/sops-age/keys.txt

# Generate a fresh age key onto /mnt — ONLY use when rotating a compromised key.
# The full key is displayed once. Save it to BitWarden before pressing Enter.
generate-age-key:
    sudo mkdir -p /mnt/var/lib/sops-age
    sudo chmod 700 /mnt/var/lib/sops-age
    sudo nix-shell -p age --run "age-keygen -o /mnt/var/lib/sops-age/keys.txt"
    sudo chmod 600 /mnt/var/lib/sops-age/keys.txt
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  SAVE THE KEY BELOW TO BITWARDEN — THIS IS THE ONLY COPY    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    sudo cat /mnt/var/lib/sops-age/keys.txt
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    read -rp "Press Enter once you have saved the key to BitWarden: "
    clear
    echo "Screen cleared. Public key (add this to .sops.yaml):"
    sudo grep "public key" /mnt/var/lib/sops-age/keys.txt
    echo ""
    echo "Next: run 'sops updatekeys' on every file under secrets/ to authorise"
    echo "this key, then commit .sops.yaml and secrets/ before rebuilding."

# Create Secure Boot signing keys and stage them for lanzaboote.
setup-secure-boot:
    echo "Generating Secure Boot keys..."
    sudo nix-shell -p sbctl --run "sbctl create-keys"
    echo "Staging keys on /mnt (lanzaboote expects keys/ subdir and GUID alongside)..."
    sudo mkdir -p /mnt/etc/secureboot/keys
    sudo chmod 700 /mnt/etc/secureboot
    sudo cp -r /var/lib/sbctl/keys/. /mnt/etc/secureboot/keys/
    sudo cp /var/lib/sbctl/GUID /mnt/etc/secureboot/GUID
    echo "Mirroring to live USB so nixos-install can sign the bootloader..."
    sudo mkdir -p /etc/secureboot
    sudo cp -r /mnt/etc/secureboot/. /etc/secureboot/
    echo "Secure Boot keys ready."

# Run nixos-install against the given host config.
nixos-install host:
    sudo nixos-install --flake .#{{host}} --no-root-passwd

# Full fresh install: partition → restore age key → secure boot keys → install.
# If rotating a compromised key, run 'just generate-age-key' first instead.
install host:
    just disko {{host}}
    just restore-age-key
    just setup-secure-boot
    just nixos-install {{host}}
