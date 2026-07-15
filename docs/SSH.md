# SSH Keys & Commit Signing

One passphrase-protected ed25519 key per machine, at `~/.ssh/id_ed25519`, used for **both** GitHub auth and git commit signing. The SSH client config and signing are declared in Nix (`modules/home/ssh.nix`, `modules/home/git.nix`); only key generation and the GitHub upload are manual.

---

## Rotate / set up this machine's key

```bash
just rotate-ssh-key
```

Backs up any existing key, generates a new ed25519 key (prompts for a passphrase you type once — macOS Keychain remembers it after that), fixes permissions, loads it into the agent, and prints the public key.

## What you MUST do manually in GitHub

Add the printed public key **twice** at <https://github.com/settings/ssh/new>:

| Key type             | Why                                            |
| -------------------- | ---------------------------------------------- |
| Authentication Key   | lets this machine `git push` / `pull` over SSH |
| Signing Key          | makes your signed commits show **Verified**    |

## Verify

- `ssh -T git@github.com` → greets you by username = auth works.
- Make a commit and push → GitHub shows a **Verified** badge = signing works.

---

## If a key is compromised

> [!IMPORTANT]
> The **Verified** badge is recomputed live — it is not frozen at commit time.

1. **Delete both GitHub entries** for that machine's key (Authentication **and** Signing) at <https://github.com/settings/keys>. This stops the attacker pushing as you and forging Verified commits.
2. Run `just rotate-ssh-key` on that machine and upload the new key (both types).
3. **Audit** what was pushed during the exposure window — assume forged commits could exist.

> [!NOTE]
> Deleting the compromised key flips **all** commits it ever signed from Verified → Unverified, retroactively. That is intended: once the key is stolen, GitHub can no longer tell your commits from forgeries. Other machines' keys are unaffected — the blast radius is one host. You normally do **not** re-sign old history (it rewrites every commit SHA).

---

## If it re-prompts for the passphrase

The agent lost the key (e.g. after reboot). Reload it into the agent + Keychain:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```
