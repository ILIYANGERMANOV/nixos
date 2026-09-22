# Secrets are scoped per host, in per-host files, under one age key

Secrets were a single `secrets/secrets.yaml` with host-suffixed keys, mapped by
hand in each host configuration:

```nix
# hosts/macos-main/configuration.nix
sops.secrets.figma-token = {
  key = "figma-token-macos-main";
  owner = config.myConfig.user.name;
};
```

Every secret therefore cost one key per host whether or not that host had any
business holding the value. `macos-main` is a personal machine with no Figma
account, so its `figma-token-macos-main` was a four-character placeholder
invented purely to keep the build working - and the Figma MCP server started
there anyway, wired to a token that was never going to authenticate. With Linear
and Coda queued behind Figma, that is N placeholders per work-only credential.

The fix has three parts.

## Secrets carry a scope, and the scope picks the file

`secrets/secrets.yaml` is gone. In its place:

- `secrets/common.yaml` - scope `global`. Every host decrypts it.
- `secrets/hosts/<hostname>.yaml` - scope `host`. Only hosts that opt in.

Secret names lose their host suffix, because the file already says which host
it belongs to. `figma-token-macos-work` is now `figma-token` inside
`secrets/hosts/macos-work.yaml`, and the NixOS user password moved from
`iliyan-password` to `password-hash` in `secrets/hosts/lenovo-old.yaml` - the
username prefix meant nothing once the file was per-host, and the value is a
yescrypt hash rather than a password.

`scope` is an explicit field and not inferred from where the declaration was
written. The module system merges every definition into one attrset and erases
its origin, so "this was declared in a host file" is not information that
survives to evaluation time. It has to be stated.

## One registry is the only door to `sops.secrets`

`modules/secrets.nix` (cross-platform, replacing the near-identical
`modules/nixos/security/sops.nix` and `modules/macos/sops.nix`) defines
`myConfig.secrets` and expands it into `sops.secrets`, deriving `sopsFile` from
`scope`, defaulting `owner` to the host's primary user, and dropping
`owner`/`mode` for `neededForUsers` secrets, which sops-nix requires to stay
root-owned. `defaultSopsFile` is gone: every secret names its own file.

A host declaration is now the whole thing:

```nix
myConfig.secrets.figma-token = { };
```

and `macos-main` declares nothing at all, which is the entire fix.

Declaring a secret is read as a **promise** that the value exists in the
matching file. That is why a missing file is an assertion failure naming the
file and the `just edit-secrets` invocation that creates it, rather than
something tolerated.

## Dependents key off availability, not off the host

`modules/home-manager.nix` passes `secretsConfig`, an attrset of name to
decrypted-file **path**, through `extraSpecialArgs` beside the existing
`userConfig` and `themeConfig`. Paths only: `sops.secrets.<n>.path` is a
build-time string and producing it decrypts nothing. No secret value may ever
enter evaluation - `builtins.readFile` on a decrypted path would bake plaintext
into a world-readable store path.

`programs/claude-code` consumes it as a plain parameter and stays
host-agnostic, as `programs/` is required to be. MCP catalog entries name the
secret they need (`secret = "figma-token"`) instead of hardcoding
`/run/secrets/figma-token`, and entries whose secret is absent are dropped from
the catalog before any flavor sees it. `claude-web-ui` still lists
`mcpServers = [ "figma" ]`; on `macos-main` that resolves to `{}` in
`~/.claude.json`, and on `macos-work` to a real server.

Flavors validate their `mcpServers` against the **full** catalog and read from
the **available** one, so a typo aborts evaluation the way an unknown skill name
already does, while a deliberately unavailable server stays silent. Those two
cases look identical from one attrset, which is why there are two.

Adding Linear now costs one line in `secrets/hosts/macos-work.yaml`, one line in
`hosts/macos-work/configuration.nix`, and one catalog entry. `macos-main` is not
edited.

## What was deliberately not done

All hosts still share one age key, so `macos-main` remains *cryptographically*
able to decrypt `secrets/hosts/macos-work.yaml`; it simply no longer has any
reason to, and nothing on it references the file. The separation is
organisational, not a trust boundary.

Per-host age keys were the alternative and would make that a real boundary. They
were declined for now because they trade the "restore one key from Bitwarden"
recovery story for a per-machine enrolment step. The layout is the expensive
half of that change and it is already done: upgrading means generating a key per
host, giving each `secrets/hosts/*.yaml` its own `creation_rules` entry in
`.sops.yaml` keyed by path, and running `sops updatekeys`. No Nix changes at all.

If a genuinely sensitive work credential ever lands in this repo, do that first.

## Consequences

The `password-hash` rename changes the key `lenovo-old` authenticates against.
The rename and the rebuild must land together; separated, that host cannot log
in.

`secrets/common.yaml` holds `example-global`, a deliberately inert value that
nothing reads. It exists so the global scope is exercised on every host on every
rebuild rather than lying untested until the first real shared secret appears.
Delete it when one does.

`just edit-secrets` takes an optional hostname (`just edit-secrets macos-work`).
It is declared as `$host`, not `host`, so just passes it as an environment
variable rather than splicing it into the recipe text - just interpolates
`{{ ... }}` textually before bash parses the line, so a plain parameter here
would be a command-injection hole.
