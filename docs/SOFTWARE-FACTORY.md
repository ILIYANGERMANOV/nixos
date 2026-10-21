# Software factory runbook

How to stand up, use and recover the `software-factory` server, step by step.
The design and its accepted risks are in `docs/adr/0007-software-factory.md`.

Every step is labelled with **where** it runs:

| Label | Where |
|---|---|
| **[mac]** | A terminal on macos-main, in this repository's directory |
| **[browser]** | Any browser, signed in to the named website |
| **[phone]** | The Fold5 |
| **[factory]** | A shell on the server as `factory` (`ssh factory@software-factory`) |
| **[admin]** | A shell on the server as `admin` (`ssh -p 2222 admin@software-factory`) |

`just` recipes always run **[mac]**. Nothing needs to be typed on the server
until step 13.

Follow the steps in order: each one only needs what the steps before it
created. Part 1 needs no server at all and ends with CI green; Part 2 creates
and installs the server.

---

## Part 1 - Accounts, keys and secrets (no server needed)

### 1. Hetzner account **[browser]** - start this first

Account verification can take from minutes to a day, so start it before
anything else and carry on with the next steps while it is pending.

1. Sign up at hetzner.com/cloud and complete the verification (identity
   and/or payment method) it asks for.
2. Turn on two-factor authentication for the account. Whoever controls it can
   open the server's web console.
3. Once verified, create a **project** named `software-factory`.
4. In that project, open **Servers** > **Add server** without creating
   anything, and check that **Shared vCPU** > **x86** > **CX43** is offered in
   Falkenstein or Nuremberg. Hetzner sometimes runs out of stock for a type in
   one location; note whichever location offers it, and close the page.

### 2. Tailscale on macos-main **[mac]**

1. Check out the `software-factory` branch (or `main`, once it is merged) and
   rebuild macos-main so the Tailscale app gets installed:
   ```sh
   just darwin-rebuild macos-main
   ```
2. Open **Tailscale** from Applications and allow the VPN configuration and the
   system extension when macOS asks.
3. Click **Log in**. Signing in for the first time creates your tailnet: choose
   the identity provider (Google, GitHub, ...) that should own it, and make
   sure that account has two-factor authentication, because it is the key to
   the tailnet.
4. From now on:
   - `just macos-main-tailscale-up` connects;
   - `just macos-main-tailscale-down` disconnects.

### 3. Tailscale on the phone **[phone]**

1. Install **Tailscale** from Google Play and sign in with the same identity.
2. Android Settings > Apps > Tailscale > Battery: **Unrestricted**.

### 4. Apply the tailnet policy **[browser]** then **[mac]**

`tailscale/policy.hujson` becomes your **entire** tailnet policy. It keeps your
own devices able to reach each other and adds the factory rules. A new tailnet
only has the default allow-all policy, so nothing is lost. If you customise the
policy later, compare it first: login.tailscale.com > **Access controls**.

1. **[browser]** login.tailscale.com > **Settings** > **Keys** > **Generate
   access token**:
   - description `policy-apply`, expiry **1 day**;
   - copy the token (it starts with `tskey-api-`). It is shown only once.
2. **[mac]** Apply the policy and paste the token when asked. The input is
   hidden.
   ```sh
   just tailscale-apply
   ```
   It validates first and changes nothing if validation fails.
3. **[browser]** Back on the **Keys** page, revoke the access token. It is no
   longer needed.

### 5. Tailscale auth key for the server **[browser]**

This must come after step 4: the key needs `tag:factory`, which the policy
defines.

1. login.tailscale.com > **Settings** > **Keys** > **Generate auth key**:
   - Reusable: **off**
   - Expiration: **90 days**. It is used once, at the server's first boot, so
     the install (step 11) must happen before it expires. If it does expire,
     repeat this step and step 9.
   - Ephemeral: **off**
   - Pre-approved: **on**
   - Tags: **on**, `tag:factory`
2. Copy the key (`tskey-auth-...`) somewhere temporary. It goes into the
   encrypted secrets in step 9.

### 6. The bot GitHub account **[browser]**

1. **Create the bot account** in a private window, with its own email address.
   Turn on 2FA.
2. **Invite it to each repository** it should work on, from your own account:
   - repository > **Settings** > **Collaborators** > **Add people**, role
     **Write**;
   - for the `Ivy-Apps` repositories, do the same from the organisation, as an
     outside collaborator with **Write**.
3. **Accept the invitations** while signed in as the bot (github.com/notifications).
4. **Protect `main`** in every one of those repositories:
   - repository > **Settings** > **Rules** > **Rulesets** > **New branch ruleset**;
   - target: the default branch; enforcement: **Active**; bypass list: **empty**;
   - turn on:
     - **Restrict deletions**;
     - **Require a pull request before merging**, with 1 required approval;
     - **Block force pushes**.
5. **Create the bot's token**, signed in as the bot:
   - **Settings** > **Developer settings** > **Personal access tokens** >
     **Tokens (classic)** > **Generate new token (classic)**;
   - note `software-factory`, expiration of your choice (you redo step 9 when
     it expires);
   - scope: **`repo`** only;
   - copy the token (`ghp_...`) somewhere temporary for step 9.

The bot's SSH key does not exist yet. It is created on the server in step 14.

### 7. Claude account settings **[browser]**

claude.ai > **Settings**, signed in with the Max account:

- **Usage** > **Extra usage**: **off**. Reaching the plan limit then pauses the
  agents instead of billing more.
- **Account** > **Trusted devices** > **Require trusted devices**: **on**.
  Every browser or phone that steers a Remote Control session has to enrol.
  The server enrols itself when it logs in, in step 15.

### 8. The server's age key **[mac]**

```sh
just factory-generate-age-key
```

1. The private key is copied to the clipboard.
2. In Bitwarden create a **Secure note** named `software-factory-age-key` and
   paste the whole clipboard into it: two comment lines, then the
   `AGE-SECRET-KEY-1...` line.
3. Press Enter. The clipboard is cleared (after 120 s even without Enter).

The recipe writes only the public key into `.sops.yaml`.

### 9. The server's secrets **[mac]**

```sh
just factory-secrets
```

It asks, in order, for:

1. **Your Mac's sudo password**: to read your existing age key, the one that
   can edit every secrets file.
2. **A new admin password**, typed twice. Save it in Bitwarden as
   `software-factory-admin-password`. You need it:
   - for every deploy (sudo);
   - for the Hetzner web console if the tailnet is ever down.
3. **The Tailscale auth key** from step 5.
4. **The bot token** from step 6.

Then commit and push, so the flake can see the new file. This is what makes
the PR's `just check` pass: until this file exists, evaluating the
software-factory host fails on purpose, because the host declares secrets that
must be in it.

```sh
git switch software-factory   # the branch of the open PR, or main once merged
git add .sops.yaml secrets/hosts/software-factory.yaml
git commit -m "[software-factory] Add the server's secrets"
git push
```

You can now delete the temporary copies of the auth key and the bot token.

---

## Part 2 - Create and install the server (about 1 hour, once)

### 10. Create the server **[browser]**

console.hetzner.com, in the `software-factory` project from step 1.

1. **Security** > **SSH keys** > **Add SSH key**: paste the output of this
   command, run **[mac]**:
   ```sh
   cat ~/.ssh/id_ed25519_sk.pub
   ```
   This key is used only for the first root login during the install.
2. **Firewalls** > **Create firewall**, named `software-factory`:
   - inbound: one rule, TCP port **22**, source: **your current IP address**.
     This rule is temporary and is removed in step 12.
   - outbound: no rules, which allows all traffic.
3. **Servers** > **Add server**:
   - Location: Falkenstein or Nuremberg.
   - Image: **Ubuntu 24.04**. It is wiped by the install.
   - Type: **Shared vCPU** > **x86** > **CX43**.
   - Networking: **Public IPv4 on**. GitHub has no IPv6, so it is required.
     IPv6 is optional.
   - SSH keys: the key you added above.
   - Firewalls: `software-factory`.
   - Backups: off.
   - Name: `software-factory`.
4. Copy the server's **public IPv4 address** from its overview page.

If Hetzner refuses the hardware-key format, use a throwaway key for
the install instead **[mac]**, and delete both copies of it after step 11:

```sh
ssh-keygen -t ed25519 -N "" -f /tmp/hetzner-install
ssh-add /tmp/hetzner-install
cat /tmp/hetzner-install.pub   # paste this into Hetzner instead
```

### 11. Install NixOS **[mac]**

```sh
just factory-install <server-ipv4>
```

1. Confirm the host key prompt with `yes`. The YubiKey blinks: touch it,
   possibly several times during the install.
2. When asked, paste the `software-factory-age-key` note from Bitwarden, then
   press **Ctrl-D** on an empty line.
3. Wait. The installer:
   - boots NixOS over Ubuntu and wipes the disk;
   - builds the system on the server, which on the current nixpkgs pin
     includes compiling Node.js: plan on **30-60 minutes**;
   - reboots.
4. About a minute after the reboot, the server joins the tailnet by itself with
   the auth key. Check login.tailscale.com > **Machines**: `software-factory`,
   tagged `tag:factory`.

### 12. Close the public port **[browser]**

console.hetzner.com > **Firewalls** > `software-factory`: delete the inbound
TCP 22 rule. Leave the firewall attached with no inbound rules. NixOS keeps the
public interface closed even without it; this is the second layer.

From here on, the server is reachable only over the tailnet.

### 13. Check both ways in **[mac]**

```sh
just macos-main-tailscale-up
ssh -p 2222 admin@software-factory   # YubiKey touch; you get a shell, then exit
ssh factory@software-factory         # Tailscale SSH: no key, no password; then exit
```

Accept each host key with `yes` the first time. If either fails, see
[Troubleshooting](#troubleshooting).

### 14. Give the bot its SSH key **[mac]** then **[browser]**

```sh
just factory-gh-key
```

This creates the key on the server and prints its public half
(`ssh-ed25519 ... software-factory`). Signed in **as the bot**:

1. github.com > **Settings** > **SSH and GPG keys** > **New SSH key**:
   - title `software-factory`, key type **Authentication Key**, paste the key.
2. **New SSH key** again with the same key, key type **Signing Key**. This is
   what makes the bot's commits show as Verified.

### 15. Log in to Claude on the server **[factory]**

```sh
ssh factory@software-factory
claude-factory
```

1. Claude Code starts its first-run setup. Choose **Claude account with
   subscription**, not an API key: the server refuses API keys anyway.
2. It prints a URL. Open it in the browser on your Mac **[browser]**, approve,
   then copy the code it shows and paste it back into the terminal.
3. If it asks whether to trust the home directory, answer yes. That prompt is
   only for this interactive run.
4. Type `/status` and check that the login method is your claude.ai Max account.
5. `/exit`.

Then, still **[factory]**, start every repository's Remote Control server:

```sh
systemctl --user restart factory-repos
systemctl --user list-units 'claude-rc@*'   # one running unit per repository
exit
```

The declared repositories (`nixos`, `deslop`, `haskell-template`) are cloned
into `~/repos` using the bot's key from step 14.

### 16. Connect the phone **[phone]**

1. Open the **Claude** app, sign in, and go to **Code**. If Trusted Devices
   asks, enrol the phone (fingerprint or face).
2. Android Settings > Apps > Claude > Battery: **Unrestricted**, so "needs your
   input" notifications arrive.
3. You should see one Remote Control server per repository, named after it.
4. For SSH from the phone (adding repositories, Part 3): install **Termux**
   from F-Droid, then in Termux:
   ```sh
   pkg install openssh
   ssh factory@software-factory
   ```
   No key is needed: Tailscale SSH authenticates the phone's tailnet identity.

### 17. First end-to-end test **[phone]**

Open the `deslop` server, start a session, and ask for something small: "add a
sentence to the README and open a PR". You should get:

- a branch pushed and a pull request opened by the bot, with Verified commits;
- a notification on the phone if the agent asks you anything.

---

## Part 3 - Daily use

- **Start work [phone]:** Claude app > Code > pick the repository's server >
  new session, e.g. `/grill-me`. Each session works in its own git worktree, so
  two sessions in one repository do not collide. Up to 2 sessions per
  repository.
- **Add a repository [phone or mac, then factory]:**
  ```sh
  ssh factory@software-factory
  factory-add git@github.com:<owner>/<repo>.git
  ```
  - Invite the bot to that repository first (step 6.2).
  - The new server appears in the app within seconds.
  - **Private repositories are only ever added this way, never in Nix.** This
    repository is public.
- **Preview an app [phone or mac]:** agents bind dev servers to ports
  3000-3099 and tell you which one. Open `http://software-factory:<port>`, on
  the Mac with Tailscale up.
- **Status [factory]:**
  - `systemctl --user list-units 'claude-rc@*'`;
  - `journalctl --user -u claude-rc@<repo> -e` for one repository's log.
- **Stop or remove a repository [factory]:**
  - `systemctl --user stop claude-rc@<repo>`;
  - to drop it for good, also `rm -rf ~/repos/<repo>`. Otherwise it starts
    again at the next boot.

## Part 4 - Changing the server (deploy) **[mac]**

Edit the configuration in this repository, then:

```sh
just macos-main-tailscale-up
just factory-cache-check   # warns if this nixpkgs rev would compile something expensive
just factory-deploy        # YubiKey touch, then the admin password for sudo
```

- The working tree is deployed as it is: committed or not, any branch.
- The server builds, then switches.
- Remote Control servers whose configuration changed restart, and their
  sessions reconnect.
- Nothing is ever deployed automatically. Merging to `main` changes nothing on
  the server until you run this.

## Part 5 - Recovery

- **Tailnet unreachable:**
  - [browser] console.hetzner.com > the server > **Console** opens a web
    terminal;
  - log in as `admin` with `software-factory-admin-password`;
  - then `sudo systemctl status tailscaled`, and `sudo tailscale up` if it is
    logged out.
- **Server reinstalled from scratch:**
  - repeat step 5 (new auth key), then `just factory-secrets` (it overwrites);
  - commit, and repeat steps 10 to 15.
  - The age key stays the same: it is in Bitwarden.
- **Age key missing on a running server [mac]:** `just factory-restore-age-key`,
  then `just factory-deploy`.
- **Bot token expired:** create a new one (step 6.5), run
  `just factory-secrets`, commit, and `just factory-deploy`.
- **Suspected compromise:** do all of these, then reinstall from scratch with a
  new age key, auth key and bot token:
  - [browser, as the bot] delete its SSH keys and token;
  - [browser] claude.ai > Settings > Account: remove the server from Trusted
    devices and sign out of all sessions;
  - [browser] login.tailscale.com > Machines: remove `software-factory`.

## Troubleshooting

- **`ssh factory@software-factory` asks for a password or is refused:**
  - check that the policy from step 4 is applied;
  - check that the server shows `tag:factory` in Machines.
- **`ssh -p 2222 admin@...` times out:** port 2222 is reachable only over the
  tailnet. Run `just macos-main-tailscale-up` first.
- **`systemctl --user` says "Failed to connect to bus" [factory]:** run
  `export XDG_RUNTIME_DIR=/run/user/$(id -u)` and retry.
- **A repository's server keeps restarting [factory]:** read its log with
  `journalctl --user -u claude-rc@<repo> -e`. The usual causes:
  - **not logged in:** repeat step 15;
  - **"Workspace not trusted":** restart the unit, which re-writes the trust
    record.
- **Clones fail [factory]:**
  - test the bot's access with `ssh -T git@github.com`. It should greet the bot
    by name;
  - if not, redo step 14, and make sure the bot accepted the repository
    invitation.
