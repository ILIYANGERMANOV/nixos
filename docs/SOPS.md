# SOPS Secrets Management

This project uses [SOPS](https://github.com/getsops/sops) with [age](https://age-encryption.org/) to encrypt secrets committed to git. The NixOS system decrypts them at runtime via [sops-nix](https://github.com/Mic92/sops-nix).

## Overview

| File | Purpose |
|------|---------|
| `.sops.yaml` | Declares which age keys can decrypt which secret files |
| `secrets/secrets.yaml` | Encrypted secrets (safe to commit) |
| `modules/nixos/security/sops.nix` | Tells sops-nix where the age key lives on the deployed machine |

The age key on the deployed machine lives at `/var/lib/sops-age/keys.txt`. This file must exist before `nixos-rebuild` can activate any configuration that references a SOPS secret.

---

## Quick start — enter the SOPS shell

All tools (`age`, `sops`, `mkpasswd`) are pinned in the `sops` dev shell:

```bash
nix develop .#sops
```

---

## One-time setup: install the age key (new macOS machine)

The age private key decrypts **everything** in `secrets/secrets.yaml`, so it must be readable by `root` only. sops-nix decrypts during activation as root and never needs your user to read the key, so locking it down does not break rebuilds.

> On macOS, keep the key at mode `600`, owned `root:wheel`. Do **not** leave it group-readable by `staff` — every admin user is in `staff`, so `640 root:staff` would let any local process (including malware running as you) read the master key.

Install the key from your password manager using the bundled recipe, which applies the correct ownership and permissions:

```bash
just darwin-install-age-key
```

Run it **before** `just darwin-bootstrap` so sops-nix can decrypt during the first activation. Verify afterwards:

```bash
ls -le /var/lib/sops-age/keys.txt
# expect: -rw-------  1 root  wheel   (no group/other read)
```

If an older install left the wrong ownership, fix it in place:

```bash
sudo chown root:wheel /var/lib/sops-age /var/lib/sops-age/keys.txt
sudo chmod 700 /var/lib/sops-age
sudo chmod 600 /var/lib/sops-age/keys.txt
```

### Generating a brand-new key

Only if you don't already have one to reuse (a new key requires re-encrypting `secrets.yaml` for the added recipient):

```bash
sudo mkdir -p /var/lib/sops-age
sudo chmod 700 /var/lib/sops-age
sudo age-keygen -o /var/lib/sops-age/keys.txt
sudo chown root:wheel /var/lib/sops-age/keys.txt
sudo chmod 600 /var/lib/sops-age/keys.txt

# Print the public key to add to .sops.yaml:
sudo grep 'public key' /var/lib/sops-age/keys.txt   # -> age1...
```

---

## Adding a new secret

### 1. Add the secret to `secrets/secrets.yaml`

Open the encrypted file with your editor (SOPS decrypts in-place, re-encrypts on save):

```bash
just edit-secrets
```

Add a new key under the YAML structure, for example:

```yaml
iliyan-password: <existing encrypted value>
my-new-secret: plaintext-value-here
```

Save and close. SOPS re-encrypts the entire file automatically.

### 2. Declare the secret in NixOS configuration

In the relevant host configuration (e.g. `hosts/lenovo-old/configuration.nix`) add:

```nix
sops.secrets.my-new-secret = { };
```

If the secret must be available during user activation (e.g. `hashedPasswordFile`), set:

```nix
sops.secrets.my-new-secret = { neededForUsers = true; };
```

The decrypted value will be available at runtime under `config.sops.secrets.my-new-secret.path`.

### 3. Use the secret path in your config

```nix
# Example: pass the decrypted file path to a service
services.someService.passwordFile = config.sops.secrets.my-new-secret.path;
```

### 4. Rebuild

```bash
sudo nixos-rebuild switch --flake .#lenovo-old
```

---

## Creating a hashed password for a NixOS user

NixOS stores passwords as hashes, not plaintext. Use `mkpasswd` (available in the `sops` dev shell) to generate one.

```bash
mkpasswd -m yescrypt
# prompts for password, prints something like:
# $y$j9T$...<hash>...
```

`yescrypt` is the recommended algorithm for NixOS 24.11+. For older systems use `sha-512`:

```bash
mkpasswd -m sha-512
```

### Store it as a SOPS secret

```bash
just edit-secrets
```

Paste the hash as the value:

```yaml
iliyan-password: '$y$j9T$...<hash>...'
```

Quote the value — the `$` characters would otherwise be misinterpreted by some tools.

### Wire it up in the NixOS config

```nix
sops.secrets.iliyan-password = { neededForUsers = true; };

users.mutableUsers = false;
users.users.iliyan = {
  hashedPasswordFile = config.sops.secrets.iliyan-password.path;
};
```

`neededForUsers = true` makes sops-nix decrypt the secret before user accounts are created during activation. Without it the file won't exist yet when NixOS tries to set the password.

---

## Adding a new machine (new age key)

When setting up a second host you need to authorise its age key to decrypt secrets.

1. Generate (or derive) the age key on the new machine as shown above.
2. Add its public key to `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
    - age:
      - age1fz8wfwqx8s6ucnsn7l0a32yp6avnaqy6vz8j4xy8ye9udgyy6urq09lfxt  # lenovo-old
      - age1<new-machine-public-key>                                        # new-host
```

3. Re-encrypt `secrets/secrets.yaml` so it is readable by all listed keys:

```bash
sops updatekeys secrets/secrets.yaml
```

4. Commit `.sops.yaml` and `secrets/secrets.yaml`.

---

## Secret ownership and permissions

By default sops-nix creates secrets owned by `root:root` with mode `0400`. Override per secret if a service needs a different owner:

```nix
sops.secrets.my-new-secret = {
  owner = "someuser";
  group = "somegroup";
  mode = "0440";
};
```

---

## Rotating the age key

If the private key is compromised, follow all four steps — skipping any one of them leaves you exposed.

1. **Rotate the actual secrets** in every upstream service (generate new passwords, revoke old API tokens, etc.). The attacker already has your plaintext values; changing the SOPS wrapper does not invalidate stolen credentials.

2. **Generate a new age key** on the machine and update `.sops.yaml` with the new public key (see "Adding a new machine" for the `.sops.yaml` format).

3. **Rotate the SOPS Data Encryption Key (DEK).** `sops updatekeys` only re-wraps the outer key — it leaves the inner DEK unchanged, so anyone with the old private key and git history can still decrypt. Force a full DEK rotation with:

   ```bash
   sops -r -i secrets/secrets.yaml
   ```

4. **Replace the old secret values** with the newly generated ones, then commit and rebuild.

---

## How sops-nix finds the key at boot

`modules/nixos/security/sops.nix` configures:

```nix
sops.age.keyFile = "/var/lib/sops-age/keys.txt";
```

sops-nix reads this file during `nixos-rebuild switch` (activation) and during `nixos-rebuild boot` (initrd). The path must exist and be readable by root before activation runs.
