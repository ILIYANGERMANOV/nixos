# Nix Darwin Install Guide

Step-by-step guide for bootstrapping nix-darwin on a Mac using the `macos-main` host configuration already defined in this repo.

> [!NOTE]
> nix-darwin brings declarative macOS system configuration — the same model as NixOS but for macOS. It manages `/etc` files, system packages, user environments (via home-manager), launchd services, and shell integration without touching anything not declared in the config.

---

## Overview of what you'll end up with

```
macOS (Apple Silicon or Intel)
├── nix-darwin system activation  →  /run/current-system
├── home-manager user environment →  ~/.nix-profile
│   ├── NeoVim (nixvim, web profile)
│   ├── Ghostty terminal (via homebrew cask)
│   ├── Zsh + Starship + eza/zoxide/fzf/ripgrep
│   └── JetBrainsMono Nerd Font
└── darwin-rebuild CLI            →  rebuild the system after config changes
```

---

## Recommended: use the darwin-install dev shell

After cloning the repo (step 2.5), enter the dedicated dev shell from the repo root:

```bash
nix develop .#darwin-install
```

This drops you into a shell with everything you need pre-loaded: `just`, `git`, `nvim` (with Nix LSP), `nixpkgs-fmt`, `age`, and `sops`. It also exports `SOPS_AGE_KEY_FILE` so all `sops` and `just edit-secrets` commands work without extra configuration, and prints a quick-reference of all available `just` commands on entry.

> [!TIP]
> All `just` commands in this guide can be run directly from inside this shell — no need to install anything else manually.

---

## Part 1 — Install Nix

Skip this part if Nix is already installed (`nix --version` prints something).

### 1.1 Install with the Determinate Systems installer

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

**Why this installer?** The official Nix installer leaves behind a multi-step mess to uninstall. The Determinate Systems installer (`nix-installer`) is fully reversible (`nix-installer uninstall`), sets up multi-user mode automatically, and enables flakes out of the box — no manual `nix.conf` editing needed.

After installation, open a **new terminal** so the `nix` command is on your PATH.

Verify:

```bash
nix --version
```

---

## Part 2 — Prepare the machine

### 2.1 Check your architecture

```bash
uname -m
```

- `arm64` → Apple Silicon → config uses `aarch64-darwin` ✓ (already set in `flake.nix`)
- `x86_64` → Intel Mac → change `flake.nix` `darwinConfigurations` entry to `"x86_64-darwin"`

### 2.2 Verify your username

The username in `hosts/macos-main/configuration.nix` must match your actual macOS login name:

```bash
id -un   # prints your login name
```

Open `hosts/macos-main/configuration.nix` and confirm `myConfig.user.name` matches the output exactly. If it doesn't, update it now — nix-darwin will fail activation with `primary user does not exist` otherwise.

### 2.3 Set the hostname

```bash
sudo scutil --set LocalHostName macos-main
sudo scutil --set ComputerName macos-main
sudo scutil --set HostName macos-main
```

Verify:

```bash
scutil --get LocalHostName   # should print: macos-main
```

> [!TIP]
> Or use the just command: `just darwin-set-hostname macos-main`

**Why three commands?** macOS has three separate hostname values: `LocalHostName` (Bonjour/mDNS), `ComputerName` (Finder/Sharing), and `HostName` (BSD kernel). nix-darwin's `networking.hostName` sets all three during activation, but you need them correct *before* the first build.

### 2.4 Back up existing `/etc` shell files

nix-darwin replaces `/etc/zshrc` and `/etc/bashrc` with its own versions. Pre-empt the conflict manually:

```bash
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
```

> [!TIP]
> Or use the just command: `just darwin-backup-etc`

> [!NOTE]
> Any new terminal you open after this step will be missing default macOS PATH entries until the bootstrap completes. Stay in your current terminal until after step 3.2.

### 2.5 Clone the repo

```bash
git clone <repo-url> ~/ivy-apps/repo/nixos
cd ~/ivy-apps/repo/nixos
```

Enter the darwin-install shell — all remaining steps should be run from inside it:

```bash
nix develop .#darwin-install
```

### 2.6 Install the SOPS age key

sops-nix decrypts secrets (including the Figma token) during `darwin-bootstrap`. The age private key must be on disk before that runs.

Open Bitwarden and copy your age private key, then run:

```bash
just darwin-install-age-key
```

Paste the key when prompted and press **Ctrl-D on a new line** to finish. The recipe will:

1. Validate the content looks like a valid age private key
2. Write it to `/var/lib/sops-age/keys.txt` (never touches a temp file)
3. Set `root:staff 750` on the directory and `root:staff 640` on the file
4. Print the public key so you can confirm it matches `.sops.yaml`

> [!IMPORTANT]
> The printed public key must match the recipient in `.sops.yaml`. If it doesn't, sops-nix will fail to decrypt during bootstrap.

---

## Part 3 — Bootstrap nix-darwin (first time only)

### 3.1 Run the bootstrap

```bash
sudo nix run --extra-experimental-features 'nix-command flakes' \
  'github:nix-darwin/nix-darwin/nix-darwin-25.11#darwin-rebuild' \
  -- switch --flake .#macos-main
```

> [!TIP]
> Or use the just command: `just darwin-bootstrap macos-main`

**Why `sudo`?** Recent nix-darwin requires activation to run as root — it writes to `/etc`, `/run/current-system`, and registers launchd services.

**Why `--extra-experimental-features`?** `sudo` drops your user environment. Passing the flag inline enables flakes without relying on your user's `nix.conf`.

**Why pin the branch?** The `flake.nix` pins nix-darwin to `nix-darwin-25.11` to match `nixpkgs/nixos-25.11`. Using the unversioned `github:nix-darwin/nix-darwin` fetches the current default branch, which may be a newer release — nix-darwin enforces a hard version match and aborts if they differ.

> [!NOTE]
> The build downloads a large number of packages on first run. Expect 5–20 minutes depending on your connection.

### 3.2 Open a new terminal

**Do not** `source /etc/zshrc`. Profile scripts guard against double-sourcing with env variables, so PATH additions are silently skipped in the existing session. Open a new terminal window for a clean environment.

Verify:

```bash
which darwin-rebuild   # should print a path under /run/current-system
darwin-rebuild --version
```

---

## Part 4 — Verify the setup

### 4.1 Check NeoVim

```bash
nvim --version
```

Neovim should launch with the Catppuccin theme, nvim-tree, Telescope, LSP, and all plugins from `programs/nvim/`.

### 4.2 Check Ghostty

Ghostty is installed as a native macOS app via homebrew (managed declaratively by nix-darwin). Find it in `/Applications/Ghostty.app` or launch from Spotlight (`⌘ Space → Ghostty`).

The config (`~/.config/ghostty/config`) is managed by home-manager — theme, font, and keybinds are all declared in `modules/home/terminal.nix`.

### 4.3 Check the font

```bash
fc-list | grep -i jetbrains
```

The JetBrainsMono Nerd Font must be present for Neovim devicons to render correctly.

---

## Part 5 — Post-install: grant Ghostty Full Disk Access

nix-darwin manages dotfiles via home-manager activation scripts that remove and re-create symlinks. Ghostty needs Full Disk Access for this to succeed — without it the activation aborts with a permission error.

### 5.1 Open Ghostty

Launch Ghostty from Spotlight (`⌘ Space → Ghostty`) or from `/Applications/Ghostty.app`. All subsequent steps should be run inside Ghostty.

### 5.2 Run the first rebuild inside Ghostty

```bash
just darwin-rebuild <host>
```

Replace `<host>` with your host name (e.g. `macos-main`). The build will likely fail with:

```
Error: Unable to remove some files. Please enable Full Disk Access for your terminal
under System Settings → Privacy & Security → Full Disk Access.
```

That error is expected — it confirms Ghostty lacks the permission. Continue to the next step.

### 5.3 Grant Full Disk Access to Ghostty

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click the **+** button and add **Ghostty** (or toggle it on if it is already listed)
3. Restart Ghostty for the permission to take effect

### 5.4 Re-run the rebuild

```bash
just darwin-rebuild <host>
```

The activation should now complete without errors. All home-manager symlinks will be created successfully.

---

## Part 6 — Day-to-day usage

### Rebuild after config changes

```bash
cd ~/ivy-apps/repo/nixos
darwin-rebuild switch --flake .#macos-main
```

> [!TIP]
> Or use the just command: `just darwin-rebuild macos-main`

### Dry-run (check the config compiles without applying)

```bash
darwin-rebuild build --flake .#macos-main
```

> [!TIP]
> Or use the just command: `just darwin-build macos-main`

### Roll back to the previous generation

```bash
darwin-rebuild rollback
```

nix-darwin keeps every previous system generation — rollback is instant with no rebuilding.

> [!TIP]
> Or use the just command: `just darwin-rollback`

### List all generations

```bash
darwin-rebuild --list-generations
```

> [!TIP]
> Or use the just command: `just darwin-generations`

---

## Troubleshooting

### sops-nix fails to decrypt secrets during bootstrap

```
Failed to get the data key required to decrypt the SOPS file.
```

This means the age key is missing, unreadable, or doesn't match the recipient in `.sops.yaml`. Check each in order:

```bash
# 1. Key file exists and is readable by your user
ls -la /var/lib/sops-age/keys.txt
# expect: -rw-r----- root staff ...

# 2. Public key matches the recipient in .sops.yaml
sudo grep 'public key' /var/lib/sops-age/keys.txt
grep 'recipient' .sops.yaml
```

If the key is missing, re-run `just darwin-install-age-key`. If permissions are wrong, fix them:

```bash
sudo chown root:staff /var/lib/sops-age /var/lib/sops-age/keys.txt
sudo chmod 750 /var/lib/sops-age
sudo chmod 640 /var/lib/sops-age/keys.txt
```

If the public key doesn't match `.sops.yaml`, you are using a different age key than the one that encrypted the secrets — copy the correct key from Bitwarden.

### `primary user does not exist`

```
error: primary user `<name>` does not exist, aborting activation
```

The username in `hosts/macos-main/configuration.nix` doesn't match your actual macOS login name. Check your login name and update the config:

```bash
id -un   # your actual login name
```

Edit `hosts/macos-main/configuration.nix`:

```nix
myConfig.user.name = "<output of id -un>";
```

Then re-run the bootstrap.

### nix-darwin / nixpkgs version mismatch

```
error: You are currently using nix-darwin 26.05 with Nixpkgs 25.11.
```

The `nix-darwin` input in `flake.nix` is missing a branch pin and picked up a newer release. Ensure the branch matches the nixpkgs branch:

```nix
nix-darwin = {
  url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then update the lock entry and retry:

```bash
nix flake update nix-darwin
```

### `/etc/zshrc` conflict error

```
error: refusing to clobber existing file '/etc/zshrc'
```

You skipped step 2.4. Move the files manually and re-run:

```bash
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin
```

### `darwin-rebuild: command not found` after bootstrap

`source /etc/zshrc` does not work in an existing shell — open a new terminal instead.

### Nix daemon not running

```
error: cannot connect to daemon at '/nix/var/nix/daemon-socket/socket'
```

```bash
sudo launchctl load /Library/LaunchDaemons/org.nixos.nix-daemon.plist
```

If that fails, re-run the Determinate Systems installer — it handles daemon registration.

### Wrong architecture in `flake.nix`

If you're on an Intel Mac and the build errors with an architecture mismatch, edit `flake.nix`:

```nix
darwinConfigurations = {
  macos-main = lib.mkDarwinSystem "macos-main" "x86_64-darwin";
};
```

Then re-run step 3.1.
