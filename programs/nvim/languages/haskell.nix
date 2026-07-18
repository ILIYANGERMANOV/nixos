{ pkgs, ... }:

{
  keymaps = [
    {
      mode = "n";
      key = "<leader>rr";
      action = ''<cmd>lua require("toggleterm").exec("cabal repl", 1)<CR>'';
      options.desc = "Haskell REPL";
    }
    {
      mode = "n";
      key = "<leader>lx";
      action = "<cmd>lua _G.HlsRestart()<CR>";
      options.desc = "Restart Haskell LSP (HLS)";
    }
  ];

  extraConfigLua = ''
    _G.HaskellRemoveUnusedImports = function()
      vim.lsp.buf.code_action({
        filter = function(action)
          return action.title == "Remove all redundant imports"
        end,
        apply = true,
      })
    end

    _G.HlsRestart = function()
      vim.lsp.stop_client(vim.lsp.get_active_clients({ name = 'hls' }))
      vim.cmd('edit')
      vim.notify("♻️  HLS Restarted", vim.log.levels.INFO)
    end

    _G.RegisterContextRunner({
      detect = function(cwd)
        return vim.fn.glob(cwd .. "/*.cabal") ~= ""
          or vim.fn.filereadable(cwd .. "/cabal.project") == 1
      end,
      run = function(action)
        if action == "test" then
          require("toggleterm").exec("cabal test --test-show-details=direct", 1)
        elseif action == "organize-imports" then
          _G.HaskellRemoveUnusedImports()
        end
      end,
    })
  '';

  autoCmd = [
    {
      event = [ "BufEnter" "CursorHold" "InsertLeave" ];
      pattern = [ "*.hs" ];
      callback = {
        __raw = "function() vim.lsp.codelens.refresh() end";
      };
    }
    {
      # Haskell indentation: nvim-treesitter's Haskell indent queries are
      # incomplete and return 0 for most positions, so pressing <CR> inside a
      # do-block dumps the cursor to column 0. Swap to plain autoindent (copy
      # the previous line's indent), which is the predictable choice for a
      # whitespace-significant language. Scoped to Haskell buffers only; every
      # other filetype keeps its global treesitter indent + smartindent.
      event = [ "FileType" ];
      pattern = [ "haskell" ];
      callback = {
        __raw = ''
          function(args)
            vim.bo[args.buf].smartindent = false
            vim.bo[args.buf].autoindent = true
            -- 4-space indent to match fourmolu (global default is 2). The
            -- where keyword lands at 2 spaces in fourmolu style; format-on-save
            -- normalizes that, so typing at multiples of 4 stays comfortable.
            vim.bo[args.buf].shiftwidth = 4
            vim.bo[args.buf].softtabstop = 4
            vim.bo[args.buf].tabstop = 4
            -- Clear treesitter's indentexpr *after* it attaches on FileType.
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(args.buf) then
                vim.bo[args.buf].indentexpr = ""
              end
            end)
          end
        '';
      };
    }
  ];

  plugins = {
    treesitter.grammarPackages = with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
      haskell
    ];

    lsp = {
      capabilities = "require('cmp_nvim_lsp').default_capabilities()";

      servers.hls = {
        enable = true;
        package = null;
        installGhc = false;
        settings = {
          haskell = {
            formattingProvider = "fourmolu";
            plugin = {
              importLens = { globalOn = true; };
              alternateNumberFormat = { globalOn = true; };
              "ghcide-type-lenses" = { globalOn = true; };
              "ghcide-code-actions-fill-hole" = { globalOn = true; };
              "ghcide-code-actions-imports-exports" = { globalOn = true; };
            };
          };
        };
      };

      keymaps.extra = [
        {
          key = "<leader>cA";
          action = "vim.lsp.codelens.run";
          options.desc = "Run CodeLens";
        }
      ];
    };

    conform-nvim.settings.formatters_by_ft = {
      haskell = [ "fourmolu" ];
      cabal = [ "cabal_fmt" ];
    };
  };
}
