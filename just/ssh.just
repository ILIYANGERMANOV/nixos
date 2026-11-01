# ─── SSH / YubiKey ───────────────────────────────────────────────────────────
# This host's SSH key is a FIDO2 resident credential living INSIDE a YubiKey
# (ed25519-sk). It is used for both GitHub auth and git commit signing.
# The private key never touches disk; every op needs a physical tap.
# Full procedures: docs/SSH.md

# Preflight: show YubiKey model, firmware, and FIDO2 PIN status.
yubikey-check:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "── Device ──────────────────────────────────────────"
    ykman info
    echo ""
    echo "── FIDO2 ───────────────────────────────────────────"
    ykman fido info
    echo ""
    echo "ed25519-sk resident keys require firmware >= 5.2.3 and a FIDO2 PIN."
    echo "If no PIN is set, run: just yubikey-set-pin"

# Set (or change) the YubiKey's FIDO2 PIN. Store it in Bitwarden.
yubikey-set-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Set a FIDO2 PIN (4-63 chars). This PIN gates enrollment and key extraction"
    echo "(ssh-keygen -K). 8 wrong tries permanently wipe the FIDO2 applet."
    echo "STORE IT IN BITWARDEN before continuing."
    echo ""
    ykman fido access change-pin

# Test that you still remember the FIDO2 PIN (verifies without changing it).
yubikey-verify-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    # shellcheck source=/dev/null
    source "{{ justfile_directory() }}/just/scripts/ssh-common.sh"
    require_fido_pin "this YubiKey"
    echo "Enter your FIDO2 PIN to confirm you still know it."
    echo "A correct PIN resets the retry counter; wrong tries count toward the 8-strike wipe."
    echo ""
    ykman fido access verify-pin
    echo ""
    echo "✓ PIN verified — you still know it, and the retry counter is reset to full."

# Enroll the PRIMARY YubiKey for this host (generate the resident credential + stub).
setup-yubikey-ssh:
    @bash "{{ justfile_directory() }}/just/scripts/setup-yubikey-ssh.sh"

# Enroll the BACKUP YubiKey for this host (plug in the SECOND key first).
enroll-backup-yubikey:
    @bash "{{ justfile_directory() }}/just/scripts/enroll-backup-yubikey.sh"

# Restore the local stub file on a fresh/rebuilt machine from the plugged-in YubiKey.
# Prompts for the FIDO2 PIN — this is why a stolen token alone is useless.
restore-ssh-stubs $which="primary":
    #!/usr/bin/env bash
    set -euo pipefail
    HOST=$(hostname -s)
    case "$which" in
      primary) DEST="$HOME/.ssh/id_ed25519_sk" ;;
      backup)  DEST="$HOME/.ssh/id_ed25519_sk_backup" ;;
      *) echo "Usage: just restore-ssh-stubs [primary|backup]" >&2; exit 1 ;;
    esac

    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    echo "Downloading resident credentials from the plugged-in YubiKey (PIN + tap)."
    ( cd "$TMP" && ssh-keygen -K )

    # ssh-keygen -K writes id_ed25519_sk_rk_<application>[.pub]; the application
    # suffix encoding varies, so match on the host substring defensively.
    MATCH=$(find "$TMP" -maxdepth 1 -name "id_ed25519_sk_rk*" ! -name "*.pub" \
      | grep -i "$HOST" | head -n1 || true)
    if [ -z "$MATCH" ]; then
      echo "Could not find a credential for host '$HOST'. Files downloaded:" >&2
      find "$TMP" -maxdepth 1 -name "id_ed25519_sk_rk*" >&2
      exit 1
    fi
    install -m 600 "$MATCH" "$DEST"
    install -m 644 "$MATCH.pub" "$DEST.pub"
    echo "Restored $which stub to $DEST"
    echo "Verify: ssh -T git@github.com"

# Rotate this host's credential on the plugged-in YubiKey (delete + regenerate).
# which: primary | backup (required) — selects the local stub file to replace.
[positional-arguments]
rotate-ssh-key $which:
    @bash "{{ justfile_directory() }}/just/scripts/rotate-ssh-key.sh" "$@"

# Verify the audible touch alert on both paths: SSH auth and commit signing.
yubikey-test-sound:
    #!/usr/bin/env bash
    set -euo pipefail
    # shellcheck disable=SC2312 # uname does not fail
    if [ "$(uname -s)" != "Darwin" ]; then
      echo "The touch alert is macOS-only (uses /usr/bin/afplay)." >&2
      exit 1
    fi
    SSH_CMD=$(git config --get core.sshCommand)
    SIGN_CMD=$(git config --get gpg.ssh.program)
    echo "── 1/2  SSH auth ───────────────────────────────────"
    echo "Contacting github.com — the alert should sound until you tap, then stop."
    # ControlPath=none forces a fresh connection: a warm ControlMaster needs no
    # tap, and correctly stays silent.
    $SSH_CMD -o ControlPath=none -T git@github.com || true
    echo ""
    echo "── 2/2  Commit signing ─────────────────────────────"
    echo "Signing a test payload — the alert should sound until you tap, then stop."
    printf 'yubikey-test-sound' | \
      $SIGN_CMD -Y sign -n test -f "$HOME/.ssh/id_ed25519_sk.pub" - >/dev/null
    echo ""
    echo "✓ Both paths alerted. If you heard nothing, check the system volume."
