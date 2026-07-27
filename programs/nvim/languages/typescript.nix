{ pkgs, ... }:

{
  autoCmd = [
    {
      event = [
        "BufRead"
        "BufNewFile"
      ];
      pattern = [ "*.mdx" ];
      command = "set filetype=mdx";
    }
  ];

  extraConfigLua = ''
    vim.treesitter.language.register('markdown', 'mdx')

    _G.RegisterContextRunner({
      detect = function(cwd)
        return vim.fn.filereadable(cwd .. "/package.json") == 1
      end,
      run = function(action)
        if action == "test" then
          require("toggleterm").exec("npm run test", 1)
        elseif action == "organize-imports" then
          vim.cmd("TSToolsRemoveUnused")
        end
      end,
    })
  '';

  plugins = {
    treesitter.grammarPackages = with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
      typescript
      tsx
      javascript
      html
      css
      markdown
      markdown_inline
    ];

    typescript-tools = {
      enable = true;
      settings = {
        # Tsserver/vtsls options can go here
        expose_as_code_action = "all";
        tsserver_file_preferences = {
          includeInlayParameterNameHints = "all";
          includeInlayFunctionParameterTypeHints = true;
        };
      };
    };

    lsp.servers = {
      biome = {
        enable = true;
        package = null;
      };
      html = {
        enable = true;
        package = null;
      };
      cssls = {
        enable = true;
        package = null;
      };
    };

    nvim-autopairs.settings.ts_config = {
      javascript = [
        "string"
        "template_string"
      ];
    };

    conform-nvim.settings.formatters_by_ft = {
      typescript = [ "biome" ];
      typescriptreact = [ "biome" ];
      javascript = [ "biome" ];
      javascriptreact = [ "biome" ];
      json = [ "biome" ];
      css = [ "biome" ];
      mdx = [ "biome" ];
    };
  };
}
