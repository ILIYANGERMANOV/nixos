# ─── Nix Darwin — Install ────────────────────────────────────────────────────
# One-time setup commands for bootstrapping nix-darwin on a new macOS machine.

# Set all three macOS hostname values (required before first bootstrap).
darwin-set-hostname host:
    sudo scutil --set LocalHostName {{host}}
    sudo scutil --set ComputerName {{host}}
    sudo scutil --set HostName {{host}}

# Back up /etc shell files that nix-darwin will replace (required before first bootstrap).
darwin-backup-etc:
    sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
    sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
    sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin

# Bootstrap nix-darwin for the first time on a machine (run after darwin-set-hostname and darwin-backup-etc).
darwin-bootstrap host:
    sudo nix run --extra-experimental-features 'nix-command flakes' \
      'github:nix-darwin/nix-darwin/nix-darwin-25.11#darwin-rebuild' \
      -- switch --flake .#{{host}}

# Paste the key from Bitwarden, then press Ctrl-D on a new line. It is written
# root-only (root:wheel, mode 600) so no process running as you can read the
# master key; see docs/SOPS.md. On a new machine this must run before
# darwin-bootstrap, so sops-nix can decrypt during the first activation. Use the
# same recipe to recover a lost or corrupted key on an already-installed Mac.
#
# Install or restore the SOPS age private key on this Mac (from Bitwarden)
darwin-install-age-key:
    @echo "Open Bitwarden, copy your age private key, paste it below, then press Ctrl-D on a new line:"
    @echo ""
    key=$(cat); \
    if ! printf '%s\n' "$key" | grep -q 'AGE-SECRET-KEY-1'; then \
      echo "Error: does not look like an age private key (missing AGE-SECRET-KEY-1 line)." >&2; \
      exit 1; \
    fi; \
    sudo mkdir -p /var/lib/sops-age; \
    printf '%s\n' "$key" | sudo tee /var/lib/sops-age/keys.txt > /dev/null; \
    sudo chown root:wheel /var/lib/sops-age; \
    sudo chmod 700 /var/lib/sops-age; \
    sudo chown root:wheel /var/lib/sops-age/keys.txt; \
    sudo chmod 600 /var/lib/sops-age/keys.txt; \
    echo ""; \
    echo "Age key installed. Public key:"; \
    sudo grep 'public key' /var/lib/sops-age/keys.txt

# Root runs age-keygen, so the private key never exists inside a process running
# as you, and the directory is made root-only before the key lands in it. Refuses
# to overwrite an existing key: a new key cannot decrypt anything encrypted to
# the old one, so to rotate deliberately move the old key aside first. Only for a
# brand-new key - to reuse a key you already have, run darwin-install-age-key.
#
# Generate a brand-new SOPS age private key on this Mac
darwin-generate-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    key_file=/var/lib/sops-age/keys.txt
    key_dir=$(dirname "$key_file")

    if ! age_keygen=$(command -v age-keygen); then
        echo "ERROR: age-keygen not found on PATH - run inside 'nix develop .#sops'" >&2
        exit 1
    fi

    sudo -v
    if sudo -n test -e "$key_file"; then
        echo "ERROR: a key already exists at $key_file" >&2
        echo "Overwriting it would destroy access to every secret encrypted to it." >&2
        echo "To rotate deliberately, move the old key aside first:" >&2
        echo "  sudo mv $key_file $key_file.old" >&2
        exit 1
    fi

    sudo install -d -o root -g wheel -m 700 "$key_dir"
    sudo "$age_keygen" -o "$key_file"
    sudo chown root:wheel "$key_file"
    sudo chmod 600 "$key_file"

    # Verify rather than assume - this is the one file whose permissions matter.
    dir_perms=$(sudo stat -f '%Sp %Su:%Sg' "$key_dir")
    key_perms=$(sudo stat -f '%Sp %Su:%Sg' "$key_file")
    if [ "$dir_perms" != "drwx------ root:wheel" ] || [ "$key_perms" != "-rw------- root:wheel" ]; then
        echo "ERROR: wrong permissions after generating:" >&2
        echo "  $key_dir: $dir_perms (want drwx------ root:wheel)" >&2
        echo "  $key_file: $key_perms (want -rw------- root:wheel)" >&2
        exit 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  SAVE THE KEY BELOW TO BITWARDEN - THIS IS THE ONLY COPY     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    sudo cat "$key_file"
    echo ""
    read -rp "Press Enter once you have saved the key to Bitwarden: "
    clear

    echo "Permissions verified:"
    echo "  $key_dir  $dir_perms"
    echo "  $key_file  $key_perms"
    echo ""
    echo "Public key (add this to .sops.yaml):"
    sudo grep 'public key' "$key_file"
    echo ""
    echo "Next: add it to .sops.yaml, then run 'sops updatekeys secrets/secrets.yaml'"
    echo "to authorise it, and commit .sops.yaml and secrets/secrets.yaml."
