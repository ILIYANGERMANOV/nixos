{ pkgs, lib, ... }:

{
  # Before every other runner: it keys on the buffer, not the project, so a
  # Python file in a repository that also has a package.json or a gradlew still
  # runs pytest.
  extraConfigLua = lib.mkBefore ''
    _G.RegisterContextRunner({
      detect = function(_)
        return vim.api.nvim_buf_get_name(0):match("%.py$") ~= nil
      end,
      run = function(action)
        if action == "test" then
          -- pytest from the project's dev shell or activated venv, run from the
          -- working directory so it finds the project's config.
          require("toggleterm").exec("pytest " .. vim.fn.shellescape(vim.fn.expand("%:.")), 1)
        elseif action == "organize-imports" then
          -- Only ruff answers: basedpyright's organize imports is off below.
          vim.lsp.buf.code_action({
            context = { only = { "source.organizeImports" } },
            apply = true,
          })
        end
      end,
    })
  '';

  plugins = {
    treesitter.grammarPackages = with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
      python
    ];

    # Binaries from modules/home/languages or the project's dev shell.
    # basedpyright owns types and hover, the same checker CI runs; ruff owns
    # lint, imports and formatting, so each side of the overlap is switched off
    # once.
    # basedpyright wraps every diagnostic pull, so every edit, in `$/progress`,
    # and noice pops each one up. Without the client's workDoneProgress it sends
    # `pyright/beginProgress` instead, which Neovim ignores; no server setting
    # turns it off. A separate call, after the servers' own, because
    # vim.lsp.config deep-merges it, while a `capabilities` on the server above
    # would replace the shared ones wholesale.
    lsp.postConfig = ''
      vim.lsp.config("basedpyright", { capabilities = { window = { workDoneProgress = false } } })
    '';

    lsp.servers = {
      basedpyright = {
        enable = true;
        package = null;
        settings.basedpyright.disableOrganizeImports = true;
        # Neovim re-analyses on every change it sends; 500 ms instead of 150
        # batches a burst of typing into one run. Neovim debounces a buffer by
        # the smallest value among its clients, so typos_lsp is set to 500 too
        # (programs/nvim/core/typos.nix).
        extraOptions.flags.debounce_text_changes = 500;
      };

      ruff = {
        enable = true;
        package = null;
        extraOptions.on_attach.__raw = ''
          function(client, _)
            client.server_capabilities.hoverProvider = false
          end
        '';
      };
    };

    conform-nvim.settings.formatters_by_ft = {
      python = [
        "ruff_organize_imports"
        "ruff_format"
      ];
    };
  };
}
