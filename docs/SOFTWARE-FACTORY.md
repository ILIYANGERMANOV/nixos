# Software factory guide

A **software factory** is a headless NixOS box that runs Claude Code agents for
you. You steer them from the Claude app on the phone (Remote Control). They
work in git worktrees, push branches as a bot account and open pull requests.

The design and its accepted risks are in `docs/adr/0007-software-factory.md`.

## Summary

There are two kinds of factory. Both run the same agent setup; they differ only
in the machine and how NixOS gets onto it.

| Kind | Host in this repo | Machine | Size |
|---|---|---|---|
| Remote | `software-factory` | Hetzner Cloud VPS (CX33, 4 vCPU / 8 GB) | `medium` |
| Local | `software-factory-lenovo` | ThinkPad T15p Gen 2 (8 cores / 16 threads, 64 GB), lid closed, 24/7 | `large` |

The hosts are listed in `factories` in `flake.nix`, hostname to platform.
Every factory recipe takes the host first: `just factory-status
software-factory-lenovo`. Below, `<host>` is one of those names.

Follow the parts in order. Each part only needs what the parts before it
created. Click a part's **Steps** to open them.

1. [Part 1 - Once per account](#part-1---once-per-account): Tailscale, the
   tailnet policy, the bot account, Claude settings. Done once, for every
   factory.
2. [Part 2 - Keys and secrets for one factory](#part-2---keys-and-secrets-for-one-factory):
   auth key, bot token, age key, secrets. Both kinds, once per factory.
3. Install, one of:
   - [Part 3 - Install on Hetzner](#part-3---install-on-hetzner) (remote);
   - [Part 4 - Install on a ThinkPad](#part-4---install-on-a-thinkpad) (local).
4. [Part 5 - After the install](#part-5---after-the-install): check the way in,
   the bot's SSH key, Claude login, the phone, a first test. Both kinds.
5. [Part 6 - Daily use](#part-6---daily-use)
6. [Part 7 - Deploy](#part-7---deploy): change a factory, or all of them.
7. [Part 8 - Recovery](#part-8---recovery)
8. [Troubleshooting](#troubleshooting)
9. [Adding a new factory](#adding-a-new-factory)

### Where each step runs

| Label | Where |
|---|---|
| **[mac]** | A terminal on macos-main, in this repository's directory |
| **[browser]** | Any browser, signed in to the named website |
| **[phone]** | The Fold5 |
| **[laptop]** | The ThinkPad's own screen and keyboard (BIOS, install USB) |
| **[box]** | A shell on the factory: `ssh factory@<host>` (the agent account) or `ssh -p 2222 admin@<host>` (admin, with sudo) |

`just` recipes always run **[mac]**. They reach the box over SSH, so nothing is
typed on the box itself except the few **[laptop]** steps of a ThinkPad
install.

---

## Part 1 - Once per account

Done once. A second factory skips this part.

<details>
<summary><b>Steps 1-5</b>: Tailscale, policy, bot account, Claude settings</summary>

### 1. Tailscale on macos-main [mac]

1. Check out `main` and rebuild macos-main, so the Tailscale app gets
   installed:
   ```sh
   just darwin-rebuild macos-main
   ```
2. Open **Tailscale** from Applications. Allow the VPN configuration and the
   system extension when macOS asks.
3. Click **Log in**. The first sign-in creates your tailnet: choose the
   identity provider (Google, GitHub, ...) that should own it. Make sure that
   account has two-factor authentication: it is the key to the tailnet.
4. From now on:
   - `just macos-main-tailscale-up` connects;
   - `just macos-main-tailscale-down` disconnects.

### 2. Tailscale on the phone [phone]

1. Install **Tailscale** from Google Play and sign in with the same identity.
2. Android Settings > Apps > Tailscale > Battery: **Unrestricted**.

### 3. Apply the tailnet policy [browser] then [mac]

`tailscale/policy.hujson` becomes your **entire** tailnet policy. It keeps your
own devices able to reach each other and adds the factory rules. A new tailnet
only has the default allow-all policy, so nothing is lost. If you change the
policy by hand later, compare it first: login.tailscale.com > **Access
controls**.

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

Every factory uses the same `tag:factory`, so a new factory needs no policy
change.

### 4. The bot GitHub account [browser]

One bot account serves every factory. Each factory gets its own token (step 7)
and its own SSH key (step 21).

1. **Create the bot account** in a private window, with its own email address.
   Turn on 2FA.
2. **Invite it to each repository** it should work on, from your own account:
   - repository > **Settings** > **Collaborators** > **Add people**, role
     **Write**;
   - for the `Ivy-Apps` repositories, do the same from the organisation, as an
     outside collaborator with **Write**.
3. **Accept the invitations** while signed in as the bot
   (github.com/notifications).
4. **Protect `main`** in every one of those repositories:
   - repository > **Settings** > **Rules** > **Rulesets** > **New branch
     ruleset**;
   - target: the default branch; enforcement: **Active**; bypass list:
     **empty**;
   - turn on:
     - **Restrict deletions**;
     - **Require a pull request before merging**, with 1 required approval;
     - **Block force pushes**.

### 5. Claude account settings [browser]

claude.ai > **Settings**, signed in with the Max account:

- **Usage** > **Extra usage**: **off**. Reaching the plan limit then pauses the
  agents instead of billing more.
- **Account** > **Trusted devices** > **Require trusted devices**: **on**.
  Every browser or phone that steers a Remote Control session has to enrol.
  A factory enrols itself when it logs in, in step 22.
- **Connectors** > **GitHub**: **connect** your own GitHub account, and install
  the Claude GitHub App on every owner the factories work on (your account and
  `Ivy-Apps`). This is not the bot's token: it is how a session attaches its
  repository (`add_repo`) and gets woken by CI results and reviews
  (`subscribe_pr_activity`). Without it agents are never woken by their pull
  requests.

</details>

---

## Part 2 - Keys and secrets for one factory

Once per factory, for both kinds. No machine is needed yet. The host must
already be in `factories` in `flake.nix`, with a `.sops.yaml` rule (see
[Adding a new factory](#adding-a-new-factory)).

On Hetzner, start step 11 (the account) first: its verification can take a day.

<details>
<summary><b>Steps 6-10</b>: auth key, bot token, age key, secrets, commit</summary>

### 6. Tailscale auth key [browser]

This must come after step 3: the key needs `tag:factory`, which the policy
defines.

1. login.tailscale.com > **Settings** > **Keys** > **Generate auth key**:
   - Reusable: **off**
   - Expiration: **90 days**. It is used once, at the factory's first boot, so
     the install must happen before it expires. If it does expire, repeat this
     step and step 9.
   - Ephemeral: **off**
   - Pre-approved: **on**
   - Tags: **on**, `tag:factory`
2. Copy the key (`tskey-auth-...`) somewhere temporary. It goes into the
   encrypted secrets in step 9.

### 7. The bot's token [browser]

One token per factory, so one can be revoked alone. Signed in **as the bot**:

1. **Settings** > **Developer settings** > **Personal access tokens** >
   **Tokens (classic)** > **Generate new token (classic)**.
2. Note `<host>`, expiration of your choice (you redo step 9 when it expires).
3. Scopes: **`repo`**, **`workflow`** and **`read:org`** (`gh pr edit` needs
   `read:org`).
4. Copy the token (`ghp_...`) somewhere temporary for step 9.

The bot's SSH key does not exist yet. It is created on the box in step 21.

### 8. The factory's age key [mac]

```sh
just factory-generate-age-key <host>
```

1. The private key is copied to the clipboard.
2. In Bitwarden create a **Secure note** named `<host>-age-key` and paste the
   whole clipboard into it: two comment lines, then the `AGE-SECRET-KEY-1...`
   line.
3. Press Enter. The clipboard is cleared (after 120 s even without Enter).

The recipe writes only the public key into `.sops.yaml`, in place of the
host's `not generated yet` marker line. If the host's secrets file exists
already, it re-encrypts it to the new key.

### 9. The factory's secrets [mac]

```sh
just factory-secrets <host>
```

It creates `secrets/hosts/<host>.yaml` if it is missing, then asks, in order,
for:

1. **Your Mac's sudo password**: to read your existing age key, the one that
   can edit every secrets file.
2. **A new admin password**, typed twice. Save it in Bitwarden as
   `<host>-admin-password`. You need it:
   - for every break-glass deploy (sudo);
   - at the box's own console if the tailnet is ever down (Hetzner web
     console, or the ThinkPad's keyboard).
3. **The Tailscale auth key** from step 6.
4. **The bot token** from step 7.
5. **The deploy token**, a fine-grained token of **your own** account, never
   the bot's. It lets the factory read and report this repository's
   deployments (Part 7):
   - [browser, as you] github.com > Settings > Developer settings >
     Fine-grained tokens > **Generate new token**;
   - name `<host>-deploy`, expiration up to a year (`factory-ctl status` warns
     30 days before it expires);
   - Repository access: **Only select repositories** > this `nixos`
     repository;
   - Permissions: **Deployments: Read and write**. Nothing else; Metadata:
     Read-only is added by GitHub on its own.

   `just factory-deploy-token <host>` writes or renews this one secret on its
   own.
6. **ThinkPad only: the Wi-Fi network** (name and password), which the box
   joins on every boot. Neither is shown as you type. `just factory-wifi
   <host>` changes it later on its own. An Ethernet cable works too, with no
   setup.

### 10. Commit the secrets [mac]

The flake only sees the file once git tracks it, and CI only once it is
pushed. Until then, evaluating the host fails on purpose, because it declares
secrets that must be in that file.

Work on a branch, never `main` (it is protected):

```sh
git switch -c <host>-secrets   # or the branch of an open PR
just factory-secrets-commit <host>
```

It commits only `.sops.yaml` and the host's secrets file, whatever else is
staged, and pushes the branch. Open a pull request and merge it: the factory's
deploys build `main`, so `main` needs the file too. The install itself builds
your working tree, so it does not wait for the merge.

You can now delete the temporary copies of the auth key and the bot token.

</details>

---

## Part 3 - Install on Hetzner

A remote factory on a Hetzner Cloud VPS. About an hour, once. For a ThinkPad,
skip to [Part 4](#part-4---install-on-a-thinkpad).

<details>
<summary><b>Steps 11-14</b>: account, server, install, close the port</summary>

### 11. Hetzner account [browser] - start this first

Account verification can take from minutes to a day, so start it before
anything else and carry on with Parts 1 and 2 while it is pending.

1. Sign up at hetzner.com/cloud and complete the verification (identity
   and/or payment method) it asks for.
2. Turn on two-factor authentication for the account. Whoever controls it can
   open the server's web console.
3. Once verified, create a **project** named after the host, such as
   `software-factory`.
4. In that project, open **Servers** > **Add server** without creating
   anything, and check that **Shared vCPU** > **x86** > **CX33** (or **CX43**)
   is offered in Falkenstein or Nuremberg. Hetzner sometimes runs out of stock
   for a type in one location; note whichever location offers it, and close
   the page.

### 12. Create the server [browser]

console.hetzner.com, in the project from step 11.

1. **Security** > **SSH keys** > **Add SSH key**: paste the output of this
   command, run **[mac]**:
   ```sh
   cat ~/.ssh/id_ed25519_sk.pub
   ```
   This key is used only for the first root login during the install.
2. **Firewalls** > **Create firewall**, named after the host:
   - inbound: one rule, TCP port **22**, source: **your current IP address**.
     This rule is temporary and is removed in step 14.
   - outbound: no rules, which allows all traffic.
3. **Servers** > **Add server**:
   - Location: Falkenstein or Nuremberg.
   - Image: **Ubuntu 24.04**. It is wiped by the install.
   - Type: **Shared vCPU** > **x86** > **CX33** (4 vCPU / 8 GB, what
     `software-factory` is sized for) or **CX43** (8 vCPU / 16 GB). Set
     `myConfig.factory.size` in `hosts/<host>/configuration.nix` to match
     before step 13: `small` for 2 vCPU / 4 GB (e.g. CPX22), `medium` for
     4 vCPU / 8 GB, `standard` for 8 vCPU / 16 GB.
   - Networking: **Public IPv4 on**. GitHub has no IPv6, so it is required.
     IPv6 is optional.
   - SSH keys: the key you added above.
   - Firewalls: the one you created above.
   - Backups: off.
   - Name: the host, such as `software-factory`.
4. Copy the server's **public IPv4 address** from its overview page.

If Hetzner refuses the hardware-key format, use a throwaway key for the
install instead **[mac]**:

```sh
just factory-install-key <host>   # paste the key it prints into Hetzner instead
```

It adds the key to this Mac's SSH agent, so the install offers it. Delete it
after step 13 (see step 14).

### 13. Install NixOS [mac]

```sh
just factory-install <host> <server-ipv4>
```

1. Confirm the host key prompt with `yes`. The YubiKey blinks: touch it,
   possibly several times during the install.
2. When asked, paste the `<host>-age-key` note from Bitwarden, then press
   **Ctrl-D** on an empty line.
3. Wait. The installer:
   - boots a NixOS installer over Ubuntu and wipes the disk;
   - builds the system on the server, which on the current nixpkgs pin
     includes compiling Node.js: plan on **30-60 minutes**;
   - reboots.
4. About a minute after the reboot, the server joins the tailnet by itself with
   the auth key. Check login.tailscale.com > **Machines**: `<host>`, tagged
   `tag:factory`.

### 14. Close the public port [browser]

console.hetzner.com > **Firewalls** > the host's firewall: delete the inbound
TCP 22 rule. Leave the firewall attached with no inbound rules. NixOS keeps the
public interface closed even without it; this is the second layer.

From here on, the server is reachable only over the tailnet.

If you used a throwaway install key in step 12, delete both copies of it now:

```sh
just factory-install-key-remove <host>   # [mac]: removes it from this Mac
```

and **[browser]** console.hetzner.com > **Security** > **SSH keys**: delete it
there by hand.

Go on with [Part 5](#part-5---after-the-install).

</details>

---

## Part 4 - Install on a ThinkPad

A local factory on a ThinkPad T15p Gen 2 that runs with its lid closed, 24/7.
About an hour, once. The install wipes the laptop's internal NVMe drive. There
is no disk encryption: the box must boot unattended after a power cut.

<details>
<summary><b>Steps 15-19</b>: BIOS, USB stick, network, install, lid closed</summary>

### 15. BIOS settings [laptop]

Power on and press **F1** to open the BIOS setup. Change these, then **F10**
to save and exit.

I could not check the exact menu names against Lenovo's T15p Gen 2 user
guide, so treat the menu paths as **verify on your machine**. The setting
names are the usual ThinkPad ones.

| Setting | Menu (verify on your machine) | Value | Why |
|---|---|---|---|
| Secure Boot | Security > Secure Boot | **Disabled** | The install and the installed system are not signed for Secure Boot |
| Boot mode | Startup > UEFI/Legacy Boot | **UEFI Only** | systemd-boot is a UEFI boot loader |
| Boot order | Startup > Boot | **USB HDD first** | To boot the install stick. The NVMe takes over once the stick is out |
| Power On with AC Attach | Config > Power | **Enabled** | The laptop turns itself on when power comes back after a cut |
| Wake On LAN | Config > Network | **AC Only** (optional) | Lets you wake it from another machine on the LAN |

Leave everything else, such as Intel SpeedStep and the thermal settings, at
its default. Nothing is needed for the display: NixOS ignores the lid.

### 16. Write the NixOS installer to a USB stick [mac]

1. **[browser]** nixos.org/download > **NixOS** > **Minimal ISO image**, the
   **Intel/AMD** (x86_64) one. Any stick of 2 GB or more works; it is wiped.
2. Plug in the stick and find its disk number:
   ```sh
   diskutil list external   # the stick is /dev/diskN, check the size
   ```
3. Write the image. Check `N` twice: `dd` overwrites whatever disk it is
   given.
   ```sh
   diskutil unmountDisk /dev/diskN
   sudo dd if=$HOME/Downloads/nixos-minimal-*.iso of=/dev/rdiskN bs=4m
   diskutil eject /dev/diskN
   ```
   It takes a few minutes and prints nothing until it is done.

### 17. Boot the installer and get on the network [laptop]

1. Plug in the stick and the charger, and power on. If it does not boot from
   USB, press **F12** at power-on for the one-time boot menu and pick the stick.
2. Pick the first entry in the NixOS boot menu. You land at a shell, logged in
   as `nixos`.
3. Three commands:
   ```sh
   sudo nmtui   # "Activate a connection", pick the Wi-Fi, type its password; skip with an Ethernet cable
   sudo passwd  # a throwaway root password, only for the install
   ip -4 a      # note the address on wlan0 or the Ethernet port, such as 192.168.x.y
   ```

The installer runs SSH and lets root log in with that password. Only your
home network can reach it, and only until the install reboots.

### 18. Install NixOS [mac]

On the same network as the laptop:

```sh
just factory-install software-factory-lenovo <laptop-ip>
```

1. When asked, type the root password you set with `passwd`. It is not shown.
2. Confirm the host key prompt with `yes`.
3. When asked, paste the `software-factory-lenovo-age-key` note from
   Bitwarden, then press **Ctrl-D** on an empty line.
4. Wait. The installer wipes the NVMe drive, builds the system on the laptop
   itself and reboots. Plan on **20-60 minutes**.
5. When it says "Installed", pull the USB stick out. The laptop boots NixOS,
   joins the Wi-Fi from step 9 and then the tailnet. Check
   login.tailscale.com > **Machines**: `software-factory-lenovo`, tagged
   `tag:factory`.

There is no firewall step: SSH is only reachable over the tailnet once NixOS
runs, and the root password from step 17 is gone with the installer.

### 19. Run it with the lid closed [laptop]

NixOS ignores the lid, never suspends, and turns the screen backlight off
after a minute. Close the lid and leave it.

- **Surface:** hard, flat and ventilated, never a bed or a sofa. With the lid
  closed the keyboard deck holds heat, and the fans take air from below.
- **Battery:** stays plugged in. NixOS holds the charge between 75 and 80 %
  (TLP), which slows its wear. The battery only bridges short power cuts.
- **Power cut:** with **Power On with AC Attach** (step 15) the laptop turns
  itself back on when power returns, boots NixOS with no one at the keyboard
  and rejoins the tailnet.
- **Hangs:** a hardware watchdog and a reboot 10 s after a kernel panic bring
  it back without you.

Go on with [Part 5](#part-5---after-the-install).

</details>

---

## Part 5 - After the install

Both kinds, once per factory.

<details>
<summary><b>Steps 20-24</b>: check the way in, bot SSH key, Claude login, phone, first test</summary>

### 20. Check both ways in [mac]

```sh
just factory-ssh-check <host>
```

It connects Tailscale on the Mac, then logs in as `admin` on port 2222 (touch
the YubiKey) and as `factory` over Tailscale SSH (no key, no password). Accept
each host key with `yes` the first time. If either fails, see
[Troubleshooting](#troubleshooting).

### 21. Give the bot its SSH key [mac] then [browser]

```sh
just factory-gh-key <host>
```

This creates the key on the box and prints its public half
(`ssh-ed25519 ... <host>`). Signed in **as the bot**:

1. github.com > **Settings** > **SSH and GPG keys** > **New SSH key**:
   - title `<host>`, key type **Authentication Key**, paste the key.
2. **New SSH key** again with the same key, key type **Signing Key**. This is
   what makes the bot's commits show as Verified.

### 22. Log in to Claude on the box [mac]

```sh
just factory-claude-login <host>
```

1. Claude Code starts its first-run setup. Choose **Claude account with
   subscription**, not an API key: the factory refuses API keys anyway.
2. It prints a URL. Open it in the browser on your Mac **[browser]**, approve,
   then copy the code it shows and paste it back into the terminal.
3. If it asks whether to trust the home directory, answer yes. That prompt is
   only for this interactive run.
4. Type `/status` and check that the login method is your claude.ai Max
   account.
5. `/exit`.

The recipe then starts every repository's Remote Control server and lists
them: one running `claude-rc@<repo>` unit per repository. The declared
repositories (`nixos`, `deslop`, `haskell-template`) are cloned into
`~/repos` with the bot's key from step 21.

### 23. Connect the phone [phone]

Items 1, 2 and 4 are once per phone; a second factory only needs item 3.

1. Open the **Claude** app, sign in, and go to **Code**. If Trusted Devices
   asks, enrol the phone (fingerprint or face).
2. Android Settings > Apps > Claude > Battery: **Unrestricted**, so
   notifications arrive. Two kinds reach the phone, both through the Claude
   app:
   - **needs your input**: sent by the app itself when an agent asks a
     question or waits on a permission prompt;
   - **agent-sent**: the factory instructions tell agents to call
     `PushNotification` when they open a PR (with its link), when the work is
     done (CI green), when they are blocked on a plain-text question, or when
     they hit a failure they cannot fix.

   These are the **Push when actions required** and **Push when Claude
   decides** toggles in `/config` of any interactive `claude` signed in to the
   same account. They are account-wide preferences, so if agent-sent pushes
   never arrive, check the second one is on. Android delivery has an open bug
   ([claude-code#87003](https://github.com/anthropics/claude-code/issues/87003)):
   if pushes stop arriving, the fallback is Claude Code hooks posting to
   ntfy.sh (#194).
3. You should see an `admin` server, and one Remote Control server per
   repository, named after it, for each factory.
4. For SSH from the phone (recovery, Part 8): install **Termux** from F-Droid,
   then in Termux:
   ```sh
   pkg install openssh
   ssh factory@<host>
   ```
   No key is needed: Tailscale SSH authenticates the phone's tailnet identity.

### 24. First end-to-end test [phone]

Open the `deslop` server, start a session, and ask for something small: "add a
sentence to the README and open a PR". You should get:

- a branch pushed and a pull request opened by the bot, with Verified commits;
- a notification on the phone if the agent asks you anything, one with the
  link when the pull request is opened, and another when CI is green, sent
  after the CI result woke the agent.

</details>

---

## Part 6 - Daily use

Starting work, running the box, adding repositories, status and logs.

<details>
<summary><b>Daily use</b></summary>

- **Start work [phone]:** Claude app > Code > pick the repository's server >
  new session, e.g. `/grill-me`. Each session works in its own git worktree, so
  two sessions in one repository do not collide. Up to 3 sessions per
  repository.
- **Run the box [phone]:** open the factory's `admin` server and start a
  session. It is always on, and its skills cover the day-to-day:

  | Skill | Does |
  |---|---|
  | `/start-repo <name or URL>` | clone if needed, start, and start at boot |
  | `/stop-repo <name>` | stop, and stay stopped across reboots |
  | `/restart-repo <name>` | restart a wedged server, or apply a deploy to it |
  | `/terminate-sessions [name]` | end live sessions; servers keep running |
  | `/status` | servers, sessions, local work, last deploy |
  | `/stats` | RAM, disk, CPU, the agents' memory cap |
  | `/free-disk` | plan, confirm, then prune pushed worktrees, caches and garbage |
  | `/deploy [rollback]` | Part 7 |
  | `/reboot`, `/gc` | root operations through fixed units |

  The skills drive `factory-ctl`, which works the same in a shell **[box]**
  (`factory-ctl help`). Anything that would end live sessions or touches
  worktrees with local work asks first.
- **Add a repository [phone]:** `/start-repo <name>` in the admin server.
  - Invite the bot to that repository first (step 4). A bare name is looked
    up among the repositories the bot can see, and the agent asks you to
    confirm which one.
  - The new server appears in the app within seconds.
  - **Private repositories are only ever added this way, never in Nix.** This
    repository is public.
  - The repositories every factory clones are in
    `modules/nixos/server/factory-defaults.nix`. A host adds one with
    `myConfig.factory.repos.<name> = "git@..."`, or replaces the list with
    `lib.mkForce`.
- **Preview an app [phone or mac]:** agents bind dev servers to ports
  3000-3099 and tell you which one. Open `http://<host>:<port>`, on the Mac
  with Tailscale up.
- **Status [mac]:** `just factory-status <host>` prints RAM and disk used and
  each repository's server with its open sessions. `just factory-status <host>
  detailed` adds recent branches, the last hour's errors and the processes
  using the most memory. Needs Tailscale up, nothing else.
- **Logs [box]:**
  - `journalctl --user -u claude-rc@<repo> -e` for one repository's server;
  - `journalctl -u factory-deploy -e` for deploys (`factory` can read the
    system journal).
- **Remove a repository for good [mac]:** `just factory-remove-repo <host>
  <repo>`. It stops the repository's server (it refuses while sessions are
  live) and deletes its clone after you type its name again. Unpushed work in
  it is lost.

</details>

---

## Part 7 - Deploy

Change a factory with a pull request, merge it, then deploy `main` to one
factory or all of them.

<details>
<summary><b>Deploy, roll back, break glass</b></summary>

### Deploy main

- **[phone]** `/deploy` in a factory's admin server deploys that factory, or
- **[browser]** Actions > **Deploy software factories** > Run workflow, on
  `main`. Pick **host**: `all` (the default) deploys every factory; a host name
  deploys that one only.

What happens:

1. The workflow refuses unless `check`, `cache-guard-aarch64-darwin`,
   `cache-guard-x86_64-linux` and `checks-x86_64` passed on main's tip. Then it
   creates a GitHub deployment for that commit in each chosen host's
   environment, named after the host. GitHub holds no credential to any
   factory.
2. Within a minute each factory sees its own deployment, checks the commit is
   still the tip of `main`, and builds it - on the box, with all of its cores.
3. It activates the new system and checks it can still be reached: Tailscale
   up, sshd running, GitHub answering. If not, it switches straight back.
   Only a healthy system becomes the boot default.
4. The result is posted to the deployment (the repository's Environments
   page) and shown by `/status`.

- **Live sessions keep running.** Remote Control servers, the admin's
  included, are not restarted by a deploy. `/restart-repo` applies a new agent
  setup to a repository; a reboot applies it everywhere.
- **Roll back:** `/deploy rollback` returns to the previous generation. Only
  two are kept.
- **Nothing deploys on merge.** Only the workflow or `/deploy` does.

### Break glass [mac]

When GitHub or the deploy path itself is broken, deploy the working tree
directly, committed or not, any branch:

```sh
just factory-break-glass <host>
```

It connects Tailscale, runs the cache guard on that host's system (it fails if
this nixpkgs rev would compile something expensive; CI runs it too), then
`just factory-deploy <host>`: touch the YubiKey, then type the admin password
for sudo. `just factory-deploy <host>` alone skips the first two.

</details>

---

## Part 8 - Recovery

The tailnet is down, a box is reinstalled, a key or token is lost or expired,
or a box is compromised.

<details>
<summary><b>Recovery</b></summary>

- **Tailnet unreachable:** log in at the box's own console as `admin` with
  `<host>-admin-password`:
  - Hetzner: [browser] console.hetzner.com > the server > **Console** opens a
    web terminal;
  - ThinkPad: [laptop] open the lid; the console is on the screen.

  Then `sudo systemctl status tailscaled`, and `sudo tailscale up` if it is
  logged out.
- **ThinkPad lost its Wi-Fi** (new router, new password): plug it into the
  router with an Ethernet cable; it gets an address on its own and rejoins the
  tailnet. Then **[mac]** `just factory-wifi <host>`, `just
  factory-secrets-commit <host>`, merge, and deploy (Part 7). Unplug the cable
  once the deploy is done.
- **Box reinstalled from scratch:**
  - repeat step 6 (new auth key), then `just factory-secrets <host>` (it
    overwrites);
  - commit with `just factory-secrets-commit <host>`, and repeat the install
    part for its kind (Part 3 or Part 4), then Part 5.
  - The age key stays the same: it is in Bitwarden.
- **Age key missing on a running box [mac]:** `just factory-restore-age-key
  <host>`, then `just factory-deploy <host>`.
- **Bot token expired:** create a new one (step 7), run `just factory-secrets
  <host>`, commit with `just factory-secrets-commit <host>`, and `just
  factory-deploy <host>`.
- **Deploy token expired or expiring:** create a new one (step 9, item 5), run
  `just factory-deploy-token <host>`, commit with `just factory-secrets-commit
  <host>`, and `just factory-deploy <host>` - the old token cannot report the
  deploy that replaces it.
- **Admin server not answering [mac]:** `just factory-restart-admin <host>`.
  It restarts on its own after a crash, so this is for a server that is up but
  wedged.
- **Suspected compromise:** do all of these, then reinstall from scratch with a
  new age key, auth key and bot token:
  - [browser, as the bot] delete that factory's SSH key and token;
  - [browser] claude.ai > Settings > Account: remove the factory from Trusted
    devices and sign out of all sessions;
  - [browser] login.tailscale.com > Machines: remove `<host>`.

  For a new age key, first replace the host's key line in `.sops.yaml` with
  its marker line (see [Adding a new factory](#adding-a-new-factory)), then
  `just factory-generate-age-key <host>`.

</details>

---

## Troubleshooting

<details>
<summary><b>Common problems</b></summary>

- **`ssh factory@<host>` asks for a password or is refused:**
  - check that the policy from step 3 is applied;
  - check that the box shows `tag:factory` in Machines.
- **`ssh -p 2222 admin@<host>` times out:** port 2222 is reachable only over
  the tailnet. Run `just macos-main-tailscale-up` first.
- **`systemctl --user` says "Failed to connect to bus" [box]:** run
  `export XDG_RUNTIME_DIR=/run/user/$(id -u)` and retry.
- **A repository's server keeps restarting [box]:** read its log with
  `journalctl --user -u claude-rc@<repo> -e`. The usual causes:
  - **not logged in:** repeat step 22;
  - **"Workspace not trusted":** restart the unit, which re-writes the trust
    record.
- **Agents say `add_repo` or `subscribe_pr_activity` was refused:**
  - "link your GitHub account": redo the GitHub connector in step 5;
  - "not configured for this session" on a repository `list_repos` does not
    show: the Claude GitHub App is not installed on that owner, or not granted
    that repository.
- **Clones fail [box]:**
  - test the bot's access with `ssh -T git@github.com`. It should greet the
    bot by name;
  - if not, redo step 21, and make sure the bot accepted the repository
    invitation.
- **A just recipe says "'x' is not a software factory":** the host name is
  wrong. The error lists the factories in `flake.nix`.
- **ThinkPad install cannot connect [mac]:** the Mac and the laptop must be on
  the same network, and `ip -4 a` on the laptop must still show the address.
  The installer's root password is lost on every reboot of the stick: redo
  step 17.
- **ThinkPad does not come back after a power cut:** check **Power On with AC
  Attach** in the BIOS (step 15).
- **ThinkPad gets hot or loud:** move it to a hard surface with room around
  the vents (step 19); `/stats` shows the load.

</details>

---

## Adding a new factory

A third factory, or a new kind of machine. Done in a pull request; then
follow Parts 2 to 5 for it.

<details>
<summary><b>Steps</b>: flake entry, host directory, secrets rule, deploy workflow</summary>

1. **`flake.nix`:** add the host to `factories`, hostname to platform:
   ```nix
   factories = {
     software-factory = "hetzner";
     software-factory-lenovo = "thinkpad-t15p";
     my-new-factory = "hetzner";
   };
   ```
   This creates `nixosConfigurations.<host>`, its activation check, and lets
   every `just factory-*` recipe accept the name. A new kind of machine also
   needs a platform module in `modules/nixos/server/platforms/` and its entry
   in `serverPlatforms` in `lib/default.nix`.
2. **`hosts/<host>/`:** `configuration.nix` with only the hostname,
   `myConfig.factory.size` (`small`, `medium`, `standard` or `large`, see
   `modules/nixos/server/resources.nix`), `system.stateVersion` and any
   overrides; and `disk-config.nix` (copy one of the existing hosts' for the
   same platform). Everything shared comes from
   `modules/nixos/server/factory-defaults.nix`.
3. **`.sops.yaml`:** a rule for `secrets/hosts/<host>.yaml` above the
   catch-all, with your Mac's key and the marker line:
   ```yaml
   - path_regex: secrets/hosts/<host>\.yaml$
     key_groups:
       - age:
           - <the macos-main key, as in the other rules>
           # <host>-age-key: not generated yet
   ```
   Do not create the secrets file by hand: `just factory-secrets <host>` does
   it in step 9.
4. **`.github/workflows/deploy-factory.yml`:** add the host to the `host`
   choice options and to `FACTORIES`. `checks.factory-deploy-hosts` fails while
   they differ from `factories`.
5. **Recipes:** nothing to add. Every factory recipe takes the host first and
   checks it against `factories`.

Until step 9 is done and pushed, CI fails for the new host: it declares
secrets its file does not have yet. That is expected.

</details>
