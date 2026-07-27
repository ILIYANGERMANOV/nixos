# SSH Keys & Commit Signing (YubiKey-backed)

Each host's SSH key is a **FIDO2 resident credential that lives inside a YubiKey** (`ed25519-sk`). The same key is used for **both** GitHub auth and git commit signing. The private key never touches disk — the files in `~/.ssh` are only *key handles* (stubs) that point at the hardware. Every SSH connection and every signed commit requires a **physical tap** on the YubiKey.

You have **two** YubiKeys per host: a **primary** (`~/.ssh/id_ed25519_sk`) you carry, and a **backup** (`~/.ssh/id_ed25519_sk_backup`) kept somewhere safe. FIDO2 credentials cannot be cloned, so each YubiKey holds its **own** independently-generated credential and both are registered on GitHub.

Config is declared in Nix (`modules/home/ssh.nix`, `modules/home/git.nix`); enrollment and GitHub upload are done through `just` recipes + the GitHub web UI.

> **macOS caveat:** Apple's `/usr/bin/ssh` (LibreSSL) cannot use `-sk` keys. The config forces the Nix build of OpenSSH (`gpg.ssh.program`, `core.sshCommand` in `git.nix`, and `pkgs.openssh` on PATH via `ssh.nix`). Keep those in place.

---

## Threat model

| Attack | Outcome |
| --- | --- |
| **Local malware** (e.g. PolinRider) tries to sign/push silently | **Blocked** — no private key on disk or in RAM; every op stalls waiting for a physical tap. |
| **YubiKey stolen alone** | **Blocked** — resident credentials can't be enumerated or extracted (`ssh-keygen -K`) without the FIDO2 PIN; 8 wrong PINs wipe the applet. |
| **YubiKey + locked MacBook stolen** | **Blocked** — stub files sit on the FileVault-encrypted disk, unreachable without login; the token still needs the PIN to extract anything. |
| **Primary YubiKey lost** | **Not locked out** — the backup YubiKey has its own credential already on GitHub. |

The one residual gap (accepted): if malware exfiltrates the stub files **and** the physical YubiKey is later stolen, the pair could be used until you revoke the GitHub key. The stub is useless without the hardware, so this requires both a software compromise and a physical theft.

---

## First-time setup (per host)

Run these on the host itself. `<host>` is `macos-main`, `macos-work`, or `lenovo-old`.

1. **Apply the Nix config** (installs FIDO OpenSSH + `ykman`, points git/ssh at the sk key):
   ```bash
   just darwin-rebuild <host>     # macOS
   just nixos-rebuild lenovo-old  # Linux
   ```
2. **Check the primary YubiKey** and set a PIN if it has none:
   ```bash
   just yubikey-check
   just yubikey-set-pin   # only if "PIN is set: false" — store the PIN in Bitwarden
   ```
3. **Enroll the primary** (prompts for PIN once, then a tap):
   ```bash
   just setup-yubikey-ssh
   ```
   This also backs up and unloads any old passphrase key. Add the printed public key to GitHub **twice** (see below).
4. **Enroll the backup** — unplug the primary, plug in the backup YubiKey (set its PIN first if needed), then:
   ```bash
   just enroll-backup-yubikey
   ```
   Add *its* printed public key to GitHub **twice** as well.
5. **Verify** (below), then delete the old passphrase key's two GitHub entries and wipe the local backup dir the recipe printed.

### What you MUST do manually in GitHub

For **each** public key (primary and backup), add it **twice** at <https://github.com/settings/ssh/new>:

| Key type            | Why                                            |
| ------------------- | ---------------------------------------------- |
| Authentication Key  | lets this machine `git push` / `pull` over SSH |
| Signing Key         | makes your signed commits show **Verified**    |

So after full setup a host has **4 GitHub entries**: primary auth + primary signing + backup auth + backup signing.

---

## Verify

- `ssh -T git@github.com` → the YubiKey LED flashes; **tap it** → GitHub greets you by username = auth works.
- `git commit --allow-empty -m "test signing"` → tap when the LED flashes → `git push` → GitHub shows a **Verified** badge = signing works.
- `ykman fido credentials list` → shows an `ssh:<host>` entry = the resident credential is on the token.
- Unplug the primary, plug in the backup, `ssh -T git@github.com` → tap → still works = backup path is good.

---

## Audible touch alert (macOS)

The LED is unreadable in bright light, so on macOS both git paths run through thin
wrappers (`programs/yubikey-touch-sound`, wired up in `modules/home/git.nix`) that
play a stock system sound on a loop while the token waits for a tap, and stop the
moment you tap. Only Apple software makes the noise: `/usr/bin/afplay` and
`/System/Library/Sounds/Hero.aiff` — the loudest of the stock sounds, amplified
with `afplay -v` so it cuts through outdoors. No daemon, no agent, no third-party
package. Sound, gain and repeat interval are arguments of
`programs/yubikey-touch-sound`.

```bash
just yubikey-test-sound   # exercises both paths; tap when you hear the alert
```

The two paths differ because OpenSSH treats them differently:

| Path | Mechanism |
| --- | --- |
| **SSH auth** (`git push`, `ssh`) | OpenSSH's own notifier: `notify_start()` forks `$SSH_ASKPASS` when a tap is needed and SIGTERMs it once you tap. The wrapper points `SSH_ASKPASS` at the alert script, puts stderr on a pipe and sets a placeholder `DISPLAY`, because the notifier only fires when stderr isn't a tty **and** a display is set. |
| **Commit signing** (`ssh-keygen -Y sign`) | No hook exists — `sign_one()` writes its notice with a bare `fprintf(stderr)` and git captures the signer's stderr, so nothing reaches your terminal at all. The wrapper alerts for the duration of the signing call instead. Verification and other subcommands pass through silently. |

Notes and limits:

- **Nothing about the threat model changes.** The alert cannot approve anything — presence is enforced in hardware. The askpass helper only ever receives the presence notice and refuses any other prompt rather than answering it; `SSH_ASKPASS_REQUIRE=force` is deliberately **not** set, so no passphrase prompt can ever be routed into it. The scripts live in `/nix/store` (immutable, hash-addressed).
- **A muted Mac hears nothing** — the alert respects system volume.
- **A warm `ControlMaster` needs no tap**, and correctly stays silent.
- Not covered: browser WebAuthn taps (macOS shows its own dialog), `ssh-keygen -K` and the enrollment recipes, and Linux hosts (`lenovo-old` keeps the plain binaries).

---

## Restore on a fresh / rebuilt machine

The stub files are the only local state, and they're trivially regenerated from the YubiKey — **the actual key is in the hardware**. On a new machine (after `darwin-rebuild`/`nixos-rebuild`), plug in a YubiKey and run:

```bash
just restore-ssh-stubs primary   # or: just restore-ssh-stubs backup
```

This runs `ssh-keygen -K` (prompts for the FIDO2 **PIN** + a tap — which is exactly why a stolen token alone is useless), finds this host's credential, and installs the stub. No GitHub changes needed — the key is unchanged.

---

## Rotation

Rotate a host's credential on whichever YubiKey is plugged in:

```bash
just rotate-ssh-key          # primary (default)
just rotate-ssh-key backup   # backup key
```

This deletes the old resident credential from the token (PIN required), generates a fresh one, and prints the new public key. **Add the new key to GitHub (Authentication + Signing) before deleting the old entries.**

> [!NOTE]
> The **Verified** badge is recomputed live. Deleting a Signing key flips **all** commits it ever signed from Verified → Unverified, retroactively. Rotate only when needed; you normally do not re-sign old history (it rewrites every commit SHA).

---

## Lost or stolen YubiKey

1. **Keep working** — your backup YubiKey already has a valid credential on GitHub. `ssh.nix` lists both stubs, so if the backup stub is present it's used automatically. If only the primary stub exists on this machine, run `just restore-ssh-stubs backup` with the backup plugged in (or copy the backup into `~/.ssh/id_ed25519_sk`).
2. **Revoke the lost key on GitHub** — delete the lost YubiKey's two entries (auth + signing) at <https://github.com/settings/keys> for **every** host it was enrolled on.
3. **Restore two-key redundancy** — buy/repurpose a new YubiKey, set its PIN, and run `just enroll-backup-yubikey` on each host, uploading the new public keys to GitHub.
4. **If the lost key turns up later**, factory-reset its FIDO2 applet before reuse: `ykman fido reset` (wipes all resident credentials on the token).

---

## FIDO2 PIN management

- **Set / change:** `just yubikey-set-pin` (wraps `ykman fido access change-pin`). Store it in Bitwarden.
- **Retry counter:** after **3** wrong PINs the FIDO2 applet locks until you re-insert the key; after **8** consecutive wrong PINs it **permanently wipes** all resident credentials. That's the anti-theft guarantee — and why the backup YubiKey matters.
- **Recover from a wipe:** the credential on that token is gone. Use the backup key, revoke the wiped key's GitHub entries, and re-enroll the token as a fresh backup.

---

## Troubleshooting

- **`sign_and_send_pubkey: signing failed` / auth hangs** — the YubiKey isn't plugged in, or you didn't tap in time (the LED flashes for ~25s). Re-run and tap.
- **`Key enrollment failed: invalid format` / `-sk` not recognized** — you're using Apple's `/usr/bin/ssh`. Ensure the Nix OpenSSH is first on PATH (`which ssh` should point into `/nix/store` or `~/.nix-profile`); the git config already pins it for git operations.
- **Commits from Neovim / a GUI git client silently hang** — the tap prompt isn't visible in that UI; listen for the touch alert (macOS) or watch for the flashing YubiKey LED, and tap. `commit.gpgsign = true` means *every* commit needs a tap.
- **No touch alert on macOS** — check the system volume first, then `git config --get core.sshCommand` / `gpg.ssh.program`: both should point at a `yubikey-touch-*` wrapper in `/nix/store`. Verify with `just yubikey-test-sound`.
- **`no FIDO2 PIN set` error from a recipe** — run `just yubikey-set-pin` first; resident-credential creation requires a PIN.
- **`ykman: command not found`** — rebuild the host so home-manager installs `yubikey-manager`, or open a new shell to pick up the updated PATH.
