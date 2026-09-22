# SOPS Secrets Management

This project uses [SOPS](https://github.com/getsops/sops) with [age](https://age-encryption.org/) to encrypt secrets committed to git. The NixOS system decrypts them at runtime via [sops-nix](https://github.com/Mic92/sops-nix).

## Overview

| File | Purpose |
|------|---------|
| `.sops.yaml` | Declares which age keys can decrypt which secret files |
| `secrets/common.yaml` | Encrypted secrets every host has (safe to commit) |
| `secrets/hosts/<hostname>.yaml` | Encrypted secrets only that host has (safe to commit) |
| `modules/secrets.nix` | The `myConfig.secrets` registry, and where the age key lives |

The age key on the deployed machine lives at `/var/lib/sops-age/keys.txt`. This file must exist before `nixos-rebuild` can activate any configuration that references a SOPS secret.

### Scopes

Every secret has a **scope**, and the scope decides which file it is read from:

| Scope | File | Meaning |
|-------|------|---------|
| `global` | `secrets/common.yaml` | Every host has it |
| `host` (default) | `secrets/hosts/<hostname>.yaml` | Only hosts that declare it |

Secret names are bare. There is no `-macos-work` suffix: the file already says
which host the value belongs to.

A host **declares** the secrets it provides, and declaring one is a promise that
a key of the same name exists in the matching file. A host that does not declare
a secret does not get it, and configuration that depends on it disables itself
there. That is why `macos-main` has no Figma MCP server and no placeholder Figma
token. See `docs/adr/0005-host-scoped-secrets.md`.

All hosts currently share one age key, so the split is organisational rather
than a trust boundary - `macos-main` *could* decrypt `secrets/hosts/macos-work.yaml`,
it simply has no reason to. The ADR records how to make it a real boundary.

---

## Quick start — where the tools come from

`age` and `sops` are installed by Home Manager on every host, so `just edit-secrets`
works from a normal shell. `mkpasswd` is not: macOS cannot hash yescrypt at all,
so `just set-password-hash` reaches for a `flake.lock`-pinned copy when the
binary is missing. The install shells carry the full set:

```bash
nix develop .#nixos-install    # installing or repairing a NixOS host
nix develop .#darwin-install   # bootstrapping a Mac
```

---

## Install or restore the age key (macOS)

The age private key decrypts **everything** under `secrets/`, so it must be readable by `root` only. sops-nix decrypts during activation as root and never needs your user to read the key, so locking it down does not break rebuilds.

> On macOS, keep the key at mode `600`, owned `root:wheel`. Do **not** leave it group-readable by `staff` — every admin user is in `staff`, so `640 root:staff` would let any local process (including malware running as you) read the master key.

Install the key from your password manager using the bundled recipe, which applies the correct ownership and permissions:

```bash
just darwin-install-age-key
```

On a new machine run it **before** `just darwin-bootstrap`, so sops-nix can decrypt during the first activation.

The same recipe recovers a lost or corrupted key on a Mac that is already set up, and `just darwin-restore-age-key` is an alias for it. Nothing else needs restoring: the key belongs at this one path, and `just edit-secrets` reads it from there. If you ever find a copy under `~/Library/Application Support/sops/age/`, delete it - it is a readable copy of the master key and nothing in this repo uses it.

Verify afterwards:

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

Only if you don't already have one to reuse (a new key requires re-encrypting every file under `secrets/` for the added recipient):

```bash
just darwin-generate-age-key
```

`root` runs `age-keygen`, so the private key is never held by a process running as you, and the directory is made root-only before the key lands in it. The recipe refuses to overwrite an existing key, verifies the resulting ownership and mode, shows the key once so you can save it to Bitwarden, then clears the screen and prints the public key.

To rotate deliberately, move the old key aside first - the recipe will not clobber it:

```bash
sudo mv /var/lib/sops-age/keys.txt /var/lib/sops-age/keys.txt.old
```

---

## Adding a new secret

### 1. Decide the scope

Does every host need it, or only some? Work-only credentials are `host`-scoped;
that is the whole point of the split.

### 2. Put the value in the right file

```bash
just edit-secrets              # secrets/common.yaml   (global)
just edit-secrets macos-work   # secrets/hosts/macos-work.yaml (host)
```

SOPS decrypts in place and re-encrypts on save. The recipe creates the file if
it does not exist yet, so this is also how a new host's secrets file is born.
Add the key under its bare name:

```yaml
my-new-secret: plaintext-value-here
```

### 3. Declare it

Host-scoped, in `hosts/<hostname>/configuration.nix`:

```nix
myConfig.secrets.my-new-secret = { };
```

Global, in `modules/secrets.nix`:

```nix
myConfig.secrets.my-new-secret.scope = "global";
```

Both accept `owner` (defaults to the host's primary user), `mode` (defaults to
`0400`, read-only for the owner) and `neededForUsers` (NixOS only - see the
password section below).

`myConfig.secrets` is the **only** way to declare a secret. Do not write
`sops.secrets` by hand: nothing downstream would see it.

### 4. Use it

Inside a NixOS or nix-darwin module, by path:

```nix
services.someService.passwordFile = config.sops.secrets.my-new-secret.path;
```

Inside Home Manager, via the `secretsConfig` special arg, which carries only the
secrets **this host** declares as `name -> path`:

```nix
{ secretsConfig, lib, ... }:
{
  # Present only where the secret is. Absent hosts get nothing, not a failure.
  programs.foo.enable = secretsConfig ? my-new-secret;
}
```

The value is only ever read at runtime, by the process that needs it. Never
`builtins.readFile` a decrypted path: that would bake the plaintext into a
world-readable store path.

### 5. Rebuild

```bash
sudo nixos-rebuild switch --flake .#lenovo-old   # or: just darwin-rebuild
```

---

## Adding a secret-gated feature

A feature that needs a secret must disable itself where the secret is absent,
rather than assume every host has it. `programs/claude-code` is the worked
example.

Catalog entries name the **secret**, not a path:

```nix
figma = mkMcpServer {
  command = "npx";
  args = [ "-y" "figma-developer-mcp" "--stdio" ];
  token = {
    secret = "figma-token";
    envVar = "FIGMA_API_KEY";
  };
};
```

`programs/` never learns which host it is building for. It receives the
`secrets` attrset as a parameter, drops entries whose secret is missing, and
resolves the survivors to real paths. A flavor listing `figma` gets a working
server on `macos-work` and `{}` on `macos-main`, with no host-specific code
anywhere in `programs/`.

Names are validated against the full catalog and read from the available one, so
a typo aborts the build while an unavailable server stays silent.

## Setting a NixOS user's password

NixOS stores a yescrypt **hash**, never the password. One recipe does the whole job:

```bash
just set-password-hash lenovo-old
```

It asks for the password twice (`mkpasswd` does not confirm, and a typo locks you
out of the host), hashes it, and writes the hash into
`secrets/hosts/lenovo-old.yaml` under `password-hash`. The password reaches
`mkpasswd` down a pipe and the hash reaches `sops` on stdin, so neither appears
in a process listing, on screen, or in any plaintext file. Other keys already in
that file are left untouched.

It works from a Mac. macOS has no `mkpasswd` and its libc cannot do yescrypt, so
the recipe falls back to a `flake.lock`-pinned `nixpkgs#mkpasswd` when nothing is
on `PATH`.

This is the **login user's** password, not root's: `users.mutableUsers` is
`false` and root has no password at all - you reach it through `sudo`.

### How it is wired up

Already done in `modules/nixos/user.nix`:

```nix
myConfig.secrets.password-hash = { neededForUsers = true; };

users.mutableUsers = false;
users.users.${cfg.name} = {
  hashedPasswordFile = config.sops.secrets.password-hash.path;
};
```

`neededForUsers = true` makes sops-nix decrypt the secret before user accounts
are created during activation. Without it the file won't exist yet when NixOS
tries to set the password. It also forces root ownership, so `owner` and `mode`
are not passed through for such secrets - sops-nix rejects them. It is
NixOS-only; setting it on a Darwin host fails an assertion in
`modules/secrets.nix`.

The key is `password-hash`, not `<user>-password`: the file is already specific
to one host, so a username prefix adds nothing, and the value is a hash rather
than a password.

**After changing it, rebuild that host from the same commit or later.** The hash
and the configuration that reads it have to move together.

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

3. Re-encrypt every secrets file so it is readable by all listed keys:

```bash
sops updatekeys secrets/common.yaml
for f in secrets/hosts/*.yaml; do sops updatekeys "$f"; done
```

4. Commit `.sops.yaml` and everything under `secrets/`.

To give each host its own key instead of sharing one - making the per-host split a
real trust boundary rather than an organisational one - give each
`secrets/hosts/*.yaml` its own `creation_rules` entry keyed by `path_regex`, then
re-run `updatekeys`. No Nix changes are needed; see `docs/adr/0005-host-scoped-secrets.md`.

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
   sops -r -i secrets/common.yaml
   for f in secrets/hosts/*.yaml; do sops -r -i "$f"; done
   ```

4. **Replace the old secret values** with the newly generated ones, then commit and rebuild.

---

## How sops-nix finds the key at boot

`modules/secrets.nix` configures:

```nix
sops.age.keyFile = "/var/lib/sops-age/keys.txt";
```

sops-nix reads this file during `nixos-rebuild switch` (activation) and during `nixos-rebuild boot` (initrd). The path must exist and be readable by root before activation runs.
