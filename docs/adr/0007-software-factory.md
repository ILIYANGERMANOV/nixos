# A headless server runs Claude Code agents, driven from a phone

The goal is a "software factory": start Claude Code sessions in any of several
repositories from the Claude app on a phone, have agents work unattended, and
get the results as GitHub pull requests that a person reviews and CI verifies.
Nothing may cost more than the flat Claude Max subscription and the server.

## The shape

`software-factory` is a NixOS host on a small cloud VM (Hetzner CX33: x86_64,
4 shared vCPU, 8 GB, 80 GB; `myConfig.factory.size` also has rows for 4 GB and
16 GB machines). x86_64 rather than ARM because this repo's
nixpkgs pin is tuned for darwin and aarch64-linux has the thinnest binary cache
coverage of the platforms involved; Haskell itself is cached on both.

- **Remote Control is the interface.** Each repository in `~/repos` gets a
  `claude remote-control --spawn worktree` server (`claude-rc@<repo>`, a systemd
  user unit). A server is bound to one directory, so the phone shows one server
  per repository, and every session it opens gets its own git worktree.
  Remote Control connects outbound to Anthropic and needs no inbound port.
- **The admin agent runs the box.** An always-on server (`claude-rc-admin`)
  serves `~/admin`, whose project skills turn repositories on and off, end
  sessions, free disk and request root operations, all through `factory-ctl`.
  It changes runtime state only; anything persistent goes through a pull
  request to this repository and a deploy. See "The admin agent" below.
- **SSH is for the one-time setup and recovery**: the `/login`, the bot's key,
  the break-glass deploy.
- **Built by `lib.mkNixosServer`**, which imports `modules/nixos/server` and none
  of the desktop modules. No other builder imports that directory, and the
  factory's Home Manager profile (`modules/home/factory`) is a separate import
  list, so no other host changes.

## Trust boundaries

Two accounts:

- `factory` runs the agents. No sudo. It holds what the agents need to work:
  the Claude login, the bot account's SSH key and token, the repositories.
- `admin` is in wheel, with sudo behind a password. It exists for the
  break-glass deploy and recovery.

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
  Tailscale SSH forwarding is disabled (`TS_SSH_DISABLE_FORWARDING`) because
  the October 2026 flaws turned it into a path from `factory` to root.
- **The cloud provider controls the hypervisor.** The disk is not encrypted:
  that would need a person to unlock it after every reboot, and it would not
  protect against the hypervisor anyway.
- **Any `factory` process can trigger the root operations.** polkit tells
  callers apart by uid only, and the admin agent and the repository agents
  share one, so a prompt-injected repository agent could also deploy, roll
  back, reboot or collect garbage. That costs availability, not secrets: none
  of these units reveals the Claude login, the SSH key or a token, and a deploy
  only ever builds the current tip of `main`, never an older commit of it.
  Reboots are refused within 10 minutes of boot so a loop cannot keep the box
  down. Each run is recorded for `factory-ctl status` and in the journal.
- **The server pulls its configuration from GitHub.** Whoever can merge to
  `main` decides what the server runs - which was already true when deploys
  were run by hand from `main`. The deploy token can only read and report this
  repository's deployments, and it is readable by root alone.

## Consequences

- Repositories are turned on and off from the phone through the admin agent,
  with no SSH and no deploy. Public repositories can also be declared in the
  host so a rebuilt server clones them itself; that only bootstraps them, and
  after the first clone the enabled set in
  `~/.local/state/factory/enabled` decides what boot starts.
- The flavor wrapper rewrites shared files under `~/.claude` at launch. The
  launcher runs it once under a lock and starts each server from the unwrapped
  binary, so concurrent starts cannot race.
- Workspace trust is written into `~/.claude.json` by the launcher, because a
  server without a terminal cannot ask for it.
- `factory-cache-check` reuses the darwin cache guard against this host.

## The admin agent

The person's main way into the factory is a Remote Control server like the
others, serving `~/admin` instead of a repository.

- **Same account, on purpose.** A separate user would need its own copy of the
  Claude login, more secrets on disk, plus privileges to manage `factory`'s
  units. As `factory` it holds nothing the repository agents do not already
  hold, and manages their units with `systemctl --user`.
- **Project-scoped skills.** `~/admin/.claude/skills` and `~/admin/CLAUDE.md`
  come from `programs/software-factory/admin`. The flavor wrapper relinks
  `~/.claude/skills` for every agent of the account, so skills placed there
  would reach the repository agents too.
- **One tested CLI.** Every skill calls `factory-ctl`, which is idempotent,
  refuses with exit code 2 whatever would end live sessions or touch worktrees
  with local work, and is exercised by `checks.software-factory`. The skills
  add judgement - which repository, whether to force - and phone-sized output.
- **Always on.** `claude-rc-admin` is outside the enabled set, restarts
  always, and keeps its memory with `MemoryMin`. A deploy does not restart it
  or any repository server (`X-SwitchMethod = keep-old`), so the session that
  asked for a deploy can report on it.
- **Idle servers are cheap.** An idle Remote Control server was measured at
  about 70 MB of private memory, sharing the Claude binary with the rest, with
  negligible CPU and network. A live session costs about 250 MB. Turning
  repositories off is for keeping the phone's list short and agents quiet, not
  for saving memory.

### Root operations

The agent account has no sudo. Four root units do what it needs, each fixed
and taking no input (`modules/nixos/server/ops.nix`):

- `factory-deploy`, on a one-minute timer, deploys the newest GitHub
  deployment of this host that has no status yet. The workflow that creates
  them (`.github/workflows/deploy-factory.yml`, manual dispatch on `main`)
  refuses unless CI passed, but it is a convenience: anyone with write access
  can create a deployment through the API, so the unit checks the commit is on
  `main` before building. It activates with `switch-to-configuration test`, so
  a reboot still boots the old system, and makes the new one the boot default
  only after a health gate (Tailscale running, sshd active, GitHub reachable).
  Otherwise it switches back. Pulling rather than pushing keeps every
  credential to the server out of GitHub.
- `factory-rollback`, `factory-reboot` and `factory-gc` may be started by
  `factory` through one polkit rule. GC keeps the current and previous
  generation of every profile, which is all a rollback reaches. Dev shells are
  not rooted (#192 chose a bigger disk over pinning them), so a GC can make
  the next `nix develop` fetch one again from the binary caches.
  Before collecting it deletes the result links builds left in `/tmp` or a
  `~/.cache` for two days: Nix registers each as an indirect GC root, and
  forgotten ones once pinned 18 GB that no GC could free. Worktree roots in
  `~/.gcroots` are left alone. `factory-ctl free-disk` deletes the agent's own
  such links without root, systemd-tmpfiles ages `/tmp` out after three days,
  and an hourly check starts `factory-gc` whenever less than 15% of `/` is
  free.
