# ─── Nix Darwin — Install ────────────────────────────────────────────────────
# One-time setup commands for bootstrapping nix-darwin on a new macOS machine.

# Set all three macOS hostname values (required before first bootstrap).
darwin-set-hostname $host:
    sudo scutil --set LocalHostName "$host"
    sudo scutil --set ComputerName "$host"
    sudo scutil --set HostName "$host"

# Back up /etc shell files that nix-darwin will replace (required before first bootstrap).
darwin-backup-etc:
    sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
    sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
    sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin

# Bootstrap nix-darwin for the first time on a machine (run after darwin-set-hostname and darwin-backup-etc).
darwin-bootstrap $host:
    sudo nix run --extra-experimental-features 'nix-command flakes' \
      --inputs-from . nix-darwin#darwin-rebuild \
      -- switch --flake ".#$host"

# Paste the key from Bitwarden, then press Ctrl-D on a new line. It is written
# root-only (root:wheel, mode 600) so no process running as you can read the
# master key; see docs/SOPS.md. The directory is made root-only before the key
# lands in it, and root writes the file under `umask 077`, so the key is never
# on disk at a mode another user could read - not even for the moment between
# the write and a chmod. On a new machine this must run before
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
    sudo install -d -o root -g wheel -m 700 /var/lib/sops-age; \
    printf '%s\n' "$key" | sudo sh -c 'umask 077; cat > /var/lib/sops-age/keys.txt'; \
    sudo chown root:wheel /var/lib/sops-age/keys.txt; \
    sudo chmod 600 /var/lib/sops-age/keys.txt; \
    echo ""; \
    echo "Age key installed. Public key:"; \
    sudo grep 'public key' /var/lib/sops-age/keys.txt

# docs/SOPS.md sends anyone recovering a lost key here, and "restore" is the
# name they reach for.
alias darwin-restore-age-key := darwin-install-age-key

# Root runs age-keygen, so the private key never exists inside a process running
# as you, and the directory is made root-only before the key lands in it. Refuses
# to overwrite an existing key: a new key cannot decrypt anything encrypted to
# the old one, so to rotate deliberately move the old key aside first. Only for a
# brand-new key - to reuse a key you already have, run darwin-install-age-key.
#
# Generate a brand-new SOPS age private key on this Mac
[positional-arguments]
darwin-generate-age-key:
    @bash just/scripts/darwin-generate-age-key.sh "$@"
