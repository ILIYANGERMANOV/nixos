---
paths:
  - "programs/claude-code/default.nix"
  - "programs/claude-code/mcp.nix"
  - "programs/claude-code/check.nix"
  - "programs/claude-code/lib.nix"
  - "programs/claude-code/secret-guard*"
  - "programs/playwright/**"
---

## Claude Code: MCP and session runtime

### Two transports, two auth stories

A catalog entry is a **local** server or a **remote** one, tagged by `type`. The
tag is the same field Claude Code reads from `~/.claude.json`, so writing an
entry out is a projection rather than a translation, and `toWire` dispatches on
it through an attrset - an unhandled transport aborts evaluation instead of
falling through to a wrong shape.

**Local (`mkStdioServer`)** - Claude Code spawns a subprocess. Its `env` maps an
environment variable to the **name** of the secret that fills it. Omitting `env`
means the server needs no secrets - an empty attrset, not a special case, so
availability is simply "every secret this server names is declared" and holds
vacuously for none. This is the only mechanism that gates a server to a host.

**Remote (`mkHttpServer`)** - Claude Code connects over HTTP and authenticates
**out-of-band**: `/mcp` inside a running session opens the OAuth flow, once per
machine. There is no secret to inject, so a remote server carries `env = { }`
and is available on every host. **A remote server cannot be host-gated by the
secrets mechanism.** Keeping one off a machine means not running a flavor that
lists it - which is why `claude-pm` exists on `macos-main` but is simply not
used there.

The OAuth grant lives in the **macOS Keychain** (on Linux,
`~/.claude/.credentials.json`) under a key derived from the server's `name`,
`type`, `url` and `headers`. Nothing about it is in `~/.claude.json`, which is
why the wrapper replacing `.mcpServers` wholesale on every launch cannot lose
it, and why switching flavors never forces a re-login. Two things do orphan a
grant: **renaming a catalog entry or changing its `url`** (one re-login), and
logging out of the Claude account, which wipes every MCP grant at once
([claude-code#90647](https://github.com/anthropics/claude-code/issues/90647)).

`mkHttpServer` takes only a `url`. Claude Code expands `${VAR}` references in
`headers` exactly as it does in `env` on a local server, so a remote server
that ever wants a static bearer token - both Linear and Superhuman Docs accept
one - is a small addition here rather than a redesign. Nothing needs it yet,
and a static token is what would let a remote server be host-gated after all.

### Session runtime and secret files

`runtime` in `default.nix` is put on PATH by every flavor wrapper: today
`programs/playwright`'s `qa` - `qa-node` (Node resolving `playwright` with
nixpkgs' Chromium, `viem` and the `qa-wallet` helper from any directory) and
`qa-mp4` (ffmpeg). The environment lives inside `qa-node`, never the session,
so a project's own Playwright keeps its own browsers. The factory's Remote
Control units run the unwrapped binary, so its profile installs `qa` too.

`secretFiles` maps an env var to a secret **name**, for a program that reads
the file itself: the wrapper exports the decrypted file's **path**, never its
value (`QA_EVM_KEY_FILE` -> `qa-sepolia-key`, declared on `macos-work` only).
A host without the secret gets no variable. Where one is exported,
`withSecretFileGuard` in `lib.nix` adds `Read` deny rules over the secrets
directory (`/run/secrets` and the `/run/secrets.d` it resolves to) and the
`claude-secret-guard` Bash hook, which blocks a command naming that directory
or the file's basename, expanding the variable, or running `printenv`/`env`
inside a command substitution. **This is protection against accidental reads,
not a security boundary**: every `qa-node` script must read the variable, so a
script (or a determined session) can read the file, and no filter over command
text can close that. `checks.qa` tests the wallet helper and the video
pipeline headless against a generated key; `checks.claude-bash-guards` the
guard.
