# A headless server runs Claude Code agents, driven from a phone

The goal is a "software factory": start Claude Code sessions in any of several
repositories from the Claude app on a phone, have agents work unattended, and
get the results as GitHub pull requests that a person reviews and CI verifies.
Nothing may cost more than the flat Claude Max subscription and the server.

## The shape

`software-factory` is a NixOS host on a small cloud VM (Hetzner CX43: x86_64,
8 shared vCPU, 16 GB, 160 GB). x86_64 rather than ARM because this repo's
nixpkgs pin is tuned for darwin and aarch64-linux has the thinnest binary cache
coverage of the platforms involved; Haskell itself is cached on both.

- **Remote Control is the interface.** Each repository in `~/repos` gets a
  `claude remote-control --spawn worktree` server (`claude-rc@<repo>`, a systemd
  user unit). A server is bound to one directory, so the phone shows one server
  per repository, and every session it opens gets its own git worktree.
  Remote Control connects outbound to Anthropic and needs no inbound port.
- **SSH is for administration only**: cloning a new repository
  (`factory-add`), the one-time `/login`, deploys.
- **Built by `lib.mkNixosServer`**, which imports `modules/nixos/server` and none
  of the desktop modules. No other builder imports that directory, and the
  factory's Home Manager profile (`modules/home/factory`) is a separate import
  list, so no other host changes.

## Trust boundaries

Two accounts:

- `factory` runs the agents. No sudo. It holds what the agents need to work:
  the Claude login, the bot account's SSH key and token, the repositories.
- `admin` is in wheel, with sudo behind a password. It exists for deploys.

Access, outermost first:

1. **The Anthropic account** steers the agents. It is protected by the account's
   own sign-in and by Trusted Devices, which ties Remote Control to enrolled
   devices.
2. **The tailnet** is the only network path in. The public interface has no
   open port, enforced by the NixOS firewall whatever the cloud firewall says.
   The server joins as `tag:factory`, and the policy
   (`tailscale/policy.hujson`) grants nothing from that tag, so it cannot
   initiate a connection to any other device.
3. **Tailscale SSH** maps the tailnet identity to `factory` only. Convenient
   from a phone: no keys to manage.
4. **OpenSSH on the tailnet interface** is the only way to `admin`, and only with
   hardware-backed keys. Becoming root therefore needs the tailnet identity and
   a physical key.

On the box:

- An nftables rule matched on the `factory` uid rejects traffic to the tailnet,
  private ranges and link-local addresses. Agents keep the open internet,
  because testing what they build requires it.
- Claude Code's managed settings are root-owned, so agents cannot edit them.
  - `forceLoginMethod: "claudeai"` and `allowedProviders: ["anthropic"]` make
    Claude Code refuse to start with an API key, a token or a non-Anthropic
    endpoint. The units also unset those variables.
  - Sessions start in auto mode, where a classifier reviews actions, and bypass
    mode cannot be entered.
  - Deny rules cover pushing to `main` and reading the credentials.
  - Deny rules match command text and are not a boundary, so they are a
    backstop to the classifier and to the account's own lack of privilege.
- Nix builds are always sandboxed, and `factory` is an allowed but never a
  trusted user of the daemon.
- The server has its own sops age key. It can decrypt
  `secrets/hosts/software-factory.yaml` and nothing else in `secrets/`.
- Memory is capped per account and oomd kills the heaviest build first, so
  runaway compilation cannot starve the services that keep the box reachable.

## Billing

The Max subscription is the only way the server can reach Claude. The managed
settings refuse API-key and gateway authentication outright. The subscription's
optional extra usage is turned off in the claude.ai account, so reaching the
plan limit stops the agents instead of billing more. Remote Control cannot run
on a `setup-token` credential, so the server holds a full login.

## Accepted risks

These are deliberate, and recorded so they are not mistaken for oversights.

- **Anything running as `factory` holds its credentials.** A prompt injection
  that gets past the classifier can use the Claude login and the bot's GitHub
  access. That is why the bot is a separate account that cannot merge into
  protected branches, and why nothing of value beyond it lives on the server.
  On suspicion: revoke the bot's keys and token, sign the server out of the
  Claude account, rebuild.
- **The bot can push branches that change CI workflows.** Its SSH key is not
  limited by token scopes. Workflows that run on a pushed branch can therefore
  see whatever secrets a repository exposes to such runs. Keeping secrets out
  of branch-triggered workflows is each repository's job.
- **Tailscale SSH to `factory` depends on the tailnet identity alone.** Losing
  that identity hands out the agent account, but not `admin` or root.
- **The cloud provider controls the hypervisor.** The disk is not encrypted:
  that would need a person to unlock it after every reboot, and it would not
  protect against the hypervisor anyway.
- **Updates are manual.** The server changes only when `just factory-deploy` is
  run from a trusted machine. Nothing pulls configuration from GitHub, so
  merging to `main` never deploys anything.

## Consequences

- Repositories are added on the box with `factory-add`, so the phone-first flow
  needs an SSH client, but no deploy. Public repositories can also be declared
  in the host so a rebuilt server clones them itself.
- The flavor wrapper rewrites shared files under `~/.claude` at launch. The
  launcher runs it once under a lock and starts each server from the unwrapped
  binary, so concurrent starts cannot race.
- Workspace trust is written into `~/.claude.json` by the launcher, because a
  server without a terminal cannot ask for it.
- `factory-cache-check` reuses the darwin cache guard against this host.
