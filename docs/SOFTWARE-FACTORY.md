# Software factory runbook

How to stand up, use and recover the `software-factory` server. The design and
its accepted risks are in `docs/adr/0007-software-factory.md`. Every `just`
recipe below runs on macos-main, from this repository.

## One-time accounts setup

1. **Bot GitHub account.** Invite it as a collaborator (write) on each
   repository it should work on. Protect `main` on every one of them: require a
   pull request with an approving review, block force pushes and deletion, no
   bypass for the bot.
2. **Bot token.** On the bot account create a classic token with the `repo`
   scope only. `gh` uses it for pull requests and CI status. Git itself pushes
   with an SSH key created on the server later.
3. **Claude account** (claude.ai settings):
   - turn extra usage off, so hitting the plan limit stops work instead of
     billing more;
   - turn on Require trusted devices.
4. **Tailscale.** Run `just tailscale-apply`. It replaces the tailnet policy
   with `tailscale/policy.hujson`, so review that file first. Then create an
   auth key: one-off, pre-approved, tagged `tag:factory`.
5. **Phone.** Install Tailscale and the Claude app. Exempt both from battery
   optimisation so notifications arrive. Install any SSH client: Tailscale SSH
   needs no key.

## Secrets

```sh
just factory-generate-age-key   # key -> clipboard -> Bitwarden as software-factory-age-key
just factory-secrets            # admin password, Tailscale auth key, bot token
```

Commit `.sops.yaml` and `secrets/hosts/software-factory.yaml`. The server's
configuration does not evaluate until that file exists.

## Install

1. In the cloud console:
   - create the server (CX43, x86) in a location of your choice;
   - add your SSH public key for the rescue system;
   - attach a firewall with one temporary inbound rule for TCP 22 from your
     current address;
   - boot the server into rescue mode.
2. `just factory-install <server-ip>` - paste the age key from Bitwarden when
   asked. The server builds its own system.
3. Delete the temporary inbound rule. Nothing inbound is needed again: the
   NixOS firewall keeps the public interface closed regardless.
4. `just macos-main-tailscale-up`. The server is now `software-factory` on the
   tailnet.
5. `just factory-gh-key`, then add the printed key to the bot account twice: as
   an authentication key and as a signing key.
6. Sign in to Claude once:
   - `ssh factory@software-factory`, run `claude-factory`, complete `/login`,
     then exit;
   - `systemctl --user restart factory-repos` clones the declared repositories
     and starts their servers.

## Daily use

- **Start work:** in the Claude app open Code. Each repository is listed as a
  `software-factory` server. Open one and start a session, for example with
  `/grill-me`. Each session works in its own worktree.
- **Add a repository:** `ssh factory@software-factory`, then
  `factory-add git@github.com:<owner>/<repo>.git`. The server appears in the
  app. Private repositories are only ever added this way, never in Nix.
- **Preview an app:** agents bind dev servers to ports 3000-3099. Open
  `http://software-factory:<port>` from the phone or from macos-main with
  Tailscale up.
- **Status:** `systemctl --user status 'claude-rc@*'`, and
  `journalctl --user -u claude-rc@<repo>` for one repository.
- **Stop a repository:** `systemctl --user stop claude-rc@<repo>`. To drop it
  for good, also delete `~/repos/<repo>`.

## Deploy

```sh
just factory-cache-check   # anything expensive to build on this nixpkgs rev?
just factory-deploy        # copies this tree, the server builds and switches
```

`sudo` asks for the admin password. A deploy restarts the Remote Control
servers whose configuration changed.

## Recovery

- **Tailnet unreachable:** use the cloud console's web terminal. Log in as
  `admin` with the admin password and inspect `tailscaled`.
- **Age key lost on the server:** `just factory-restore-age-key`, then deploy.
- **Suspected compromise:**
  - revoke the bot's SSH keys and token on GitHub;
  - remove the server's trusted device and sign it out in the Claude account
    settings;
  - remove the node in the Tailscale console;
  - then rebuild from scratch with a new age key, a new auth key and a new bot
    token.
