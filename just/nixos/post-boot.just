# ─── Post-boot ───────────────────────────────────────────────────────────────
# Run these on the installed machine after first boot.

# Enroll Secure Boot keys into UEFI firmware.
# Prerequisite: enter Setup Mode in BIOS first (clear OEM keys).
enroll-secure-boot:
    sudo sbctl setup --migrate
    sudo sbctl enroll-keys --microsoft

# Rebuild and switch the system to the latest flake configuration.
nixos-rebuild host:
    sudo nixos-rebuild switch --flake .#{{ host }}
