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

Rather OpenCode on DeepSeek? See [opencode-kategory](#opencode-opencode-kategory).

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

## OpenCode: opencode-kategory

> [!NOTE]
> Early. The skills and roles are there. The hooks are not wired yet: see
> [Known gaps](#known-gaps).

`opencode-kategory` is the same harness in [OpenCode](https://opencode.ai),
on DeepSeek models. Same skills, same roles, same `state` program.

### Run it

Set your DeepSeek key, then start it from your project:

```sh
export DEEPSEEK_API_KEY=<your key>
nix run "github:ILIYANGERMANOV/nixos#opencode-kategory"
```

Every skill is also a command. Arguments pass through to `opencode`. Run one
headless, with no UI:

```sh
opencode-kategory run --command engineer "<task>"
```

In a CI runner such as GitHub Actions, use the headless flavor below.

### Headless

`opencode-kategory-headless` is for a run with nobody there, such as a CI job:

```sh
export DEEPSEEK_API_KEY=<your key>
nix run "github:ILIYANGERMANOV/nixos#opencode-kategory-headless" -- \
  run --auto "<prompt>" </dev/null
```

- `--auto` allows what would otherwise wait for a yes. Use it only where the
  runner is the sandbox.
- `</dev/null`: `run` reads stdin to its end when it is not a terminal.
- The lead answers every question itself with its recommended option, its
  subagents' questions too. It records each answer with `state`.
- It never ends its turn while work remains. It waits for workers and CI in
  the foreground.
- Its final text lists every decision (question, answer, why) and every
  action: commits, pull requests, reviews posted.
- OpenCode's question tool is off.
- Its data, state and cache live in `~/.opencode-kategory-headless`.

#### Example: review pull requests in GitHub Actions

DeepSeek's key is the only model secret. `GH_TOKEN` lets `gh` post the review.

```yaml
name: review
on:
  pull_request:
permissions:
  contents: read
  pull-requests: write
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: cachix/install-nix-action@75c75c31ebece974e48ebc36b4ad125bd97bd97b # v31.11.3
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - name: Review
        env:
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
          GH_TOKEN: ${{ github.token }}
          OPENCODE_DISABLE_PROJECT_CONFIG: "1"
          PR: ${{ github.event.pull_request.number }}
        run: |
          nix run "github:ILIYANGERMANOV/nixos#opencode-kategory-headless" -- \
            run --auto "Review pull request #$PR. Post one review with gh api: COMMENT with inline comments, or APPROVE." </dev/null
```

The agent posts the review through GitHub's
[create a review](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request)
API. `event` is `COMMENT` or `APPROVE`. Each inline comment names a file
and a line of the diff:

```sh
gh api repos/{owner}/{repo}/pulls/<n>/reviews --method POST --input - <<'EOF'
{
  "event": "COMMENT",
  "body": "Two findings.",
  "comments": [
    {"path": "src/app.ts", "line": 12, "side": "RIGHT", "body": "This throws on an empty list."}
  ]
}
EOF
```

> [!WARNING]
> The run reads the pull request's code, and every shell it runs sees the
> job's secrets.
>
> - A pull request can change `.opencode/`, `opencode.json` or `AGENTS.md`.
>   OpenCode loads them, and plugins are code. `OPENCODE_DISABLE_PROJECT_CONFIG=1`
>   skips them all, the project's `AGENTS.md` too.
> - Use `pull_request`. A pull request from a fork gets no secrets there, so
>   it gets no review.
> - Never use `pull_request_target` with a checkout of the pull request's
>   head: that runs its code with your secrets.
> - `APPROVE` with `GITHUB_TOKEN` needs the repository setting "Allow GitHub
>   Actions to create and approve pull requests".

### Models

| Who | Model |
|---|---|
| Lead, large roles | `deepseek/deepseek-v4-pro` |
| Small and medium roles | `deepseek/deepseek-flash` |

`--model`, a project `opencode.json` or `.opencode/opencode.json` wins over
the lead's model. The roles keep theirs.

### Isolation

- OpenCode's own data, state and cache live in `~/.opencode-kategory`.
- It never reads `~/.claude`, `~/.agents` or `~/.config/opencode`.
- Its config is read-only dirs in the Nix store: the harness config and an
  empty global config dir. So OpenCode installs no npm package on launch.
- Your project's `CLAUDE.md` still loads. It stacks with an `AGENTS.md`.
- Shells it runs get your own config, data and cache dirs back. So `gh` and
  `git` use your login and config.
- `state` keeps its own `kernel.db`, in
  `~/.opencode-kategory/state/state/kernel.db`. Sharing one with
  `claude-kategory` is a follow-up.

### Permissions

- Each role may use only the tools it needs. Everything else is denied.
- Outside the project, every agent may use `/tmp/**`, `~/.10x/**` and
  `/nix/store/**` without asking.
- A skill marked `disable-model-invocation` (such as `chief`) runs only as
  its command. The model cannot invoke it.

A project's own OpenCode config (`.opencode/`, `opencode.json`) loads and
runs, plugins too. So a pull request that changes it runs that change. A later
review pipeline must treat it as code under review. OpenCode can skip it with
`OPENCODE_DISABLE_PROJECT_CONFIG`. `opencode-kategory` does not set it.

### Known gaps

- **No hooks yet.** The kernel's gate, the guards and hand-back recording do
  not run. They come in the next step.
- **`~/.opencode` is always read.** OpenCode has no switch to turn it off.
- **A writable `.opencode/` costs an npm install.** OpenCode runs
  `npm install @opencode-ai/plugin` in every config dir it can write: a
  project's `.opencode/` or `~/.opencode`, where one exists. Online that
  takes seconds. Offline it waits about 70 seconds. In GitHub Actions, cache
  that dir's `node_modules` or make the dir read-only.
- **Headless answers log as the user's.** `state` has no answerer but the
  user, so the headless lead's own answers are recorded as `by: user`. Its
  final text names them as its own.
- **Missing tools.** No agent can stop another. No push notifications or
  PR-activity wake-ups: those steps are skipped.
- **macOS.** Shells get `XDG_CONFIG_HOME` set. A tool that reads `~/Library`
  when it is unset reads `~/.config` instead. `gh` and `git` read `~/.config`
  either way.

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
