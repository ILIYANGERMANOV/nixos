# claude-kategory

Claude Code with this repository's agent harness: the skills, subagent roles,
hooks and guards of the software factory. It keeps everything in
`~/.claude-kategory`, so your own `~/.claude` and `~/.claude.json` are never
touched.

> [!WARNING]
> ## Disclaimer
>
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

## Install

1. Install Nix, if you do not have it yet, with the
   [Determinate Nix installer](https://docs.determinate.systems/):

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```

   Open a new terminal afterwards.

2. Start `claude-kategory` from the `main` branch:

   ```sh
   nix run github:ILIYANGERMANOV/nixos#claude-kategory
   ```

   The first launch builds it and asks you to log in. To keep it on your
   `PATH` as `claude-kategory`, install it instead:

   ```sh
   nix profile add github:ILIYANGERMANOV/nixos#claude-kategory
   ```

Runs on macOS (Apple silicon) and Linux (x86_64, aarch64).

## What you can change

- **Yours, kept across launches:** login, `settings.json` (`/model`,
  `/config`), plugins and MCP servers (`/mcp`, `claude-kategory mcp add ...`).
- **Set by Nix on every launch:** the harness skills, roles and `CLAUDE.md`
  (rewritten on disk), and its hooks and guards (passed from the Nix store).
