# claude-kategory

`claude-kategory` is kategory's Claude Code build: a harness-wrapper that
runs each task as a state machine. Give `/engineer` a task and it hands back
a pull request. Why it is built this way: [docs/harness/README.md](harness/README.md).

Everything lives in `~/.claude-kategory`, so your own `~/.claude` and
`~/.claude.json` stay untouched.

> [!WARNING]
> Experimental and use at your own risk: agents read files, run commands and
> can send what they read to Anthropic, GitHub and MCP servers. Read the
> [Disclaimer](#disclaimer) first.

Runs on macOS (Apple silicon) and Linux (x86_64, aarch64).

## Prerequisites

- **Nix.** Already installed? Skip this. Otherwise install it with the
  [Determinate Nix installer](https://docs.determinate.systems/), then open a
  new terminal:

  ```sh
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
  ```

- **GitHub login**, so the agents can open pull requests. Already logged in
  with any `gh` (from Nix, Homebrew or elsewhere)? Skip this: every `gh` shares
  the same stored login. Otherwise log in, no `gh` install needed:

  ```sh
  nix run "nixpkgs#gh" -- auth login
  ```

## Quickstart: try it

1. Start it from your own project, the git repository you want the agents to
   work on. One line, nothing to clone: Nix fetches and builds it from GitHub.
   The first launch asks you to log in to Claude:

   ```sh
   nix run "github:ILIYANGERMANOV/nixos#claude-kategory"
   ```

   Keep the quotes: zsh, the macOS shell, treats `#` as a special character.

2. Give `/engineer` one task:

   ```text
   /engineer <task: what you want changed>
   ```

   It researches, asks you each decision as a question, builds the change
   through subagents, reviews it and hands back a pull request with green
   CI.

3. Many requests in one session, a question to discuss or a quick fix? Use
   `/chief`. It routes each request to the right flow:

   ```text
   /chief <prompt: anything you want>
   ```

   Stopped halfway? `/chief resume` picks it up.

## Install for good

Liked it? Put `claude-kategory` on your `PATH`, then start it from any
project:

```sh
nix profile add "github:ILIYANGERMANOV/nixos#claude-kategory"
claude-kategory
```

To remove it: `nix profile remove claude-kategory`.

## What you get

The skills to run, `/engineer` first:
[Where to start](harness/README.md#where-to-start).

It is built for the author's headless "software factory" server. On a laptop
the factory-only parts do not apply: `/10x-engineer`, push notifications and
PR-activity wake-ups.

## What you can change

- **Yours, kept across launches:** login, `settings.json` (`/model`,
  `/config`), plugins and MCP servers (`/mcp`, `claude-kategory mcp add ...`).
- **Set by Nix on every launch:** the harness skills, roles and `CLAUDE.md`
  (rewritten on disk), and its hooks and guards (passed from the Nix store).

## Update

New commits land on `main` often. One command takes the latest:

| You use | Update with |
|---|---|
| Install for good | `nix profile upgrade --refresh claude-kategory` |
| Quickstart | `nix run --refresh "github:ILIYANGERMANOV/nixos#claude-kategory"` |

`--refresh` makes Nix check GitHub again. Without it Nix may reuse a cached
copy for up to an hour and stay on an old version.

## Disclaimer

> [!WARNING]
> - **Use at your own risk.** This is a personal, experimental setup, provided
>   "as is", with no warranty of any kind. See the [LICENSE](../LICENSE).
> - **No liability.** The authors are not liable for any damage, data loss,
>   leaked data, costs or other harm from using it.
> - **It can leak your data.** The agents read files, run commands and use
>   the network on your machine. What they read can be sent to Anthropic, to
>   GitHub and to any MCP server you add.
> - **Not security-audited.** The guards are best effort and can miss
>   things. Do not run it on machines or repositories holding secrets or data
>   you cannot afford to expose.
> - **It stores data locally.**
>   - The `state` program keeps run logs, questions, answers, decisions and
>     state in a local SQLite database, `~/.local/state/state/kernel.db`
>     (`$XDG_STATE_HOME/state/kernel.db` when set).
>   - Claude Code keeps your login, transcripts, settings and MCP servers in
>     `~/.claude-kategory`.
>   - Helper files go in `/tmp`, `~/.10x` and git worktrees inside your
>     repositories.
>
> By running it you accept these terms.
