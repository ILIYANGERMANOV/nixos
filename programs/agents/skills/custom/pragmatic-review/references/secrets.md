# Secrets handling - the DEEP blockers checklist

Read by the blockers agent at DEEP depth when its prompt names this file,
after the step-1 sweep of `blockers.md`. The sweep already hunts
literal credentials and committed secret files; this checklist hunts the paths
a secret travels at runtime. Run the greps at the bottom on `$D/diff` first,
then walk the checklist against every place the diff reads, passes, stores,
prints or builds a secret. A hit you cannot refute is a blocker: name the
attacker, the entry point and the gain, as `blockers.md` says.

## Trigger

The `secrets.md` row of the routing table in `first-pass.md` Phase 1.

## Checklist

The attacker reads something the diff makes readable; the gain is in brackets.

### Logs, errors, telemetry

- A secret, token, cookie, `Authorization` header or connection string passed
  to a logger, `print`, `console.log`, `set -x`, a debug dump of a request,
  config or env object (`console.log(process.env)`, `logger.info(config)`)
  [anyone with log access, log vendors].
- An exception or error response that includes the config, the query with
  credentials, or the upstream response body carrying a token; a stack trace
  returned to the client [the caller].
- Analytics, Sentry or tracing capturing headers, bodies or env unscrubbed
  [the vendor and its breaches].

### URLs and client bundles

- A token or key in a query string, path or redirect URL [logs, history,
  `Referer` to third parties].
- A server secret exposed under a public prefix (`NEXT_PUBLIC_`, `VITE_`,
  `REACT_APP_`, `EXPO_PUBLIC_`, `PUBLIC_`), imported into client code, or
  inlined by a bundler `define` [every visitor].
- A mobile or desktop app shipping a backend secret; only publishable keys
  (Stripe `pk_`, Supabase anon with RLS on) belong client-side [extraction
  from the binary].

### Build artefacts and images

- Nix: a secret's value reaching the store - `builtins.readFile` on a
  decrypted path, a secret in a derivation attribute, `writeText`,
  `environment.etc` text, a systemd `Environment=` or a module option that is
  rendered into a unit file [every local user: `/nix/store` is world-readable,
  and caches and substituters copy it]. Expect a runtime path:
  `config.sops.secrets.<n>.path`, `EnvironmentFile=`, `LoadCredential=`.
- Docker: a secret in `ENV`, `ARG`, `COPY`ed into a layer, or `RUN` writing it
  then deleting it in a later layer [anyone who pulls the image; `docker
  history` shows `ARG`s]. Expect BuildKit `--mount=type=secret` or runtime
  injection; `.dockerignore` covering `.env*` and keys.
- A secret written into a build output, generated config, sourcemap, artifact
  or cache [whoever downloads it]. CI-specific paths are in `ci-security.md`.

### Files, permissions, processes

- A secret file written with default permissions (`0644`), to `/tmp` without
  `mktemp`, or into a git-tracked or synced directory [other local users].
- sops-nix: a secret's `owner`, `group` or `mode` widened beyond the one
  service that reads it; a `restartUnits` missing so a rotated value is never
  picked up [lateral reads, stale credentials].
- A secret on a command line (`--password=`, `curl -u`, `mysql -p...`)
  [`ps`, shell history, `/proc/<pid>/cmdline` for every user].
- A child process, plugin, template or MCP server handed the whole parent
  environment when it needs one variable [the child and its dependencies].

### Repository rules and sops

- A new secret not routed through the repository's one door (here:
  `myConfig.secrets`; a hand-written `sops.secrets` is a finding) or with the
  wrong scope [host gets a secret it should not, or the build breaks].
- A placeholder or default value added so a build passes on a host without the
  secret; code that assumes every host has every secret instead of gating on
  availability [a fake credential ships, or a silent fallback].
- A plaintext file next to its encrypted twin; a `.sops.yaml` `creation_rules`
  change that drops a recipient or adds an unknown age or PGP key; an
  encrypted file's `sops:` metadata stripped [decryption by the wrong party,
  or a plaintext commit].
- An age or GPG private key, `keys.txt`, or `SOPS_AGE_KEY` value in the repo or
  a world-readable path [every secret encrypted to it].

### Exposure response

- A diff that removes a leaked secret without rotating it: deleting it from the
  tip leaves it in history, forks, caches and clones, and public GitHub leaks
  are exploited within minutes [the secret is still live]. Require rotation and
  revocation first; history rewrite is optional and secondary.
- A new long-lived, unscoped or never-expiring credential where a short-lived,
  scoped one exists (OIDC, workload identity, fine-grained token) [blast
  radius of any leak].

## Grep, on the diff

Run all five in one turn. Each matches added lines only (`^\+`), so line
numbers stay those of `diff`. A hit is a lead: read the hunk.

```sh
rg -n -i '^\+.*(log|print|console\.|debug|info|warn|error|dump|Sentry|capture).*(secret|token|password|passwd|api_?key|authorization|cookie|credential|process\.env|os\.environ|config\b)' "$D/diff"
rg -n '^\+.*(NEXT_PUBLIC_|VITE_|REACT_APP_|EXPO_PUBLIC_|PUBLIC_)[A-Z_]*(SECRET|TOKEN|KEY|PASSWORD|PRIVATE)' "$D/diff"
rg -n '^\+.*(readFile[^;]*(secret|sops|/run/)|sops\.secrets\.|Environment\s*=.*(KEY|TOKEN|SECRET|PASS)|writeText.*(secret|token|key)|mode\s*=\s*"0?[0-7][0-7][4-7]")' "$D/diff"
rg -n -i '^\+\s*((ENV|ARG)\s+\w*(secret|token|key|pass)|COPY .*(\.env|\.pem|id_rsa|keys\.txt|credentials))' "$D/diff"
rg -n -i '^\+.*([?&](token|key|api_key|secret|password|access_token)=|--password[= ]|curl .*-u |chmod [0-7]*[4-7]\b.*(key|secret|\.env)|age1[0-9a-z]{58}|AGE-SECRET-KEY-)' "$D/diff"
```

## Sources

- https://cheatsheetseries.owasp.org/ (Secrets Management, Logging)
- https://www.gitguardian.com/state-of-secrets-sprawl-report-2026
- https://docs.docker.com/build/building/secrets/
- https://nix.dev/manual/nix/latest/store/ (store paths are world-readable)
- https://github.com/Mic92/sops-nix
- https://github.com/getsops/sops
- https://nextjs.org/docs/app/guides/environment-variables
- `.claude/rules/secrets.md` (paths only, never values; declaration is a promise)
