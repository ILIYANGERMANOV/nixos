# Build-time tests for the Neovim config, wired into `nix flake check` (and
# therefore `just check` in CI) as `checks.nvim-typescript`.
#
# What prompted this check: TypeScript 7 removed lib/tsserver.js, so the server
# that had been serving every project could no longer start. Nix was happy -
# the config built, and the failure only appeared at runtime as a Lua error in
# a buffer - so the routing is asserted here against real fixture roots in a
# real headless Neovim rather than reasoned about in Nix.
#
# No language server is started: nothing is `:edit`ed, no filetype is set, and
# the `root_dir` hooks are called directly on named buffers. That keeps the
# check hermetic and fast, and is also its limit - it proves which server
# claims a root, not that the server then starts.
{
  pkgs,
  inputs,
  root,
}:

let
  inherit (pkgs.stdenv.hostPlatform) system;

  nvim = inputs.nixvim.legacyPackages.${system}.makeNixvimWithModule {
    inherit pkgs;
    module = import "${root}/programs/nvim";
    extraSpecialArgs = { inherit root; };
  };

  assertions = pkgs.writeText "nvim-typescript-assertions.lua" ''
    local failures = {}

    local function expect(what, actual, wanted)
      if actual ~= wanted then
        table.insert(failures, string.format("%s: expected %s, got %s", what, vim.inspect(wanted), vim.inspect(actual)))
      end
    end

    local servers = { "vtsls", "tsc" }

    -- What each server claims for one file: its root, or nil where it
    -- declines. Both are asked about the same buffer, which is the situation
    -- being tested.
    --
    -- The buffer is unlisted but NOT scratch: `vim.fs.root` returns nil for
    -- any buffer whose buftype is not "", so a scratch buffer would make every
    -- root_dir fall through to its cwd fallback and the whole check pass
    -- vacuously. Nothing is `:edit`ed and no filetype is set, so no language
    -- server attaches inside the sandbox.
    local function claimedRoots(file)
      local bufnr = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(bufnr, file)

      local claimed = {}
      for _, server in ipairs(servers) do
        vim.lsp.config[server].root_dir(bufnr, function(dir)
          claimed[server] = dir
        end)
      end

      return claimed
    end

    -- Given: one project root per era, plus a file belonging to neither.
    local cwd = vim.fn.getcwd()
    local classic = cwd .. "/classic"
    local native = cwd .. "/native"

    local routing = {
      { file = classic .. "/a.ts", server = "vtsls", root = classic },
      { file = native .. "/a.ts", server = "tsc", root = native },
      -- No lockfile and no .git anywhere above it: the era probe falls back to
      -- the working directory, finds no classic service, and the native server
      -- takes it. This is the loose-scratch-file path.
      { file = cwd .. "/loose.ts", server = "tsc", root = cwd },
    }

    -- Then: the expected server claims the root and the other one declines.
    -- Asserting both directions is the point - two servers claiming the same
    -- root means duplicate diagnostics and duplicate completions.
    for _, case in ipairs(routing) do
      local claimed = claimedRoots(case.file)
      for _, server in ipairs(servers) do
        local wanted = (server == case.server) and case.root or nil
        expect(string.format("%s claims %s", server, case.file), claimed[server], wanted)
      end
    end

    -- Then: the native server prefers the project's own tsc, and falls back to
    -- the one on PATH for a root that has none.
    local binaries = {
      { root = native, wanted = native .. "/node_modules/.bin/tsc" },
      { root = classic, wanted = "tsc" },
    }

    for _, case in ipairs(binaries) do
      expect("tsc binary for " .. case.root, _G.TsNativeBinary(case.root), case.wanted)
    end

    -- Then: loading the config raised nothing. This catches a broken Lua
    -- chunk, not a server that fails to start - no server is started here.
    local messages = vim.api.nvim_exec2("messages", { output = true }).output
    if messages:match("E%d+:") or messages:lower():match("error") then
      table.insert(failures, "startup messages: " .. messages)
    end

    if #failures > 0 then
      io.stderr:write("nvim-typescript: " .. #failures .. " assertion(s) failed\n")
      for _, failure in ipairs(failures) do
        io.stderr:write("  - " .. failure .. "\n")
      end
      vim.cmd("cquit 1")
    end

    -- A Lua error inside `-c luafile` aborts the chunk but leaves Neovim's
    -- exit code at 0, so the builder cannot rely on that alone. Reaching this
    -- line is the only proof every assertion above actually ran.
    vim.fn.writefile({ "ok" }, vim.env.NVIM_TYPESCRIPT_SENTINEL)

    io.stdout:write("nvim-typescript: routing and binary resolution OK\n")
  '';
in

pkgs.runCommand "nvim-typescript-check" { nativeBuildInputs = [ nvim ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  cd "$TMPDIR"

  # A classic root: the era probe looks for exactly this file, and nothing
  # reads its contents.
  mkdir -p classic/node_modules/typescript/lib
  touch classic/pnpm-lock.yaml classic/node_modules/typescript/lib/tsserver.js
  touch classic/a.ts

  # A native root: TypeScript 7 ships no tsserver.js, only the tsc binary.
  mkdir -p native/node_modules/.bin
  touch native/pnpm-lock.yaml
  printf '#!/bin/sh\nexit 0\n' > native/node_modules/.bin/tsc
  chmod +x native/node_modules/.bin/tsc
  touch native/a.ts

  # Belongs to no project: no lockfile and no .git above it.
  touch loose.ts

  export NVIM_TYPESCRIPT_SENTINEL="$TMPDIR/passed"
  nvim --headless -c 'luafile ${assertions}' -c 'qa!'

  if [ ! -f "$NVIM_TYPESCRIPT_SENTINEL" ]; then
    echo "nvim-typescript: the assertions did not run to completion" >&2
    exit 1
  fi

  touch $out
''
