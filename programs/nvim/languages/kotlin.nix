{ pkgs, ... }:

{
  extraConfigLua = ''
    _G.RegisterContextRunner({
      detect = function(cwd)
        return vim.fn.filereadable(cwd .. "/gradlew") == 1
          or vim.fn.filereadable(cwd .. "/settings.gradle") == 1
          or vim.fn.filereadable(cwd .. "/settings.gradle.kts") == 1
      end,
      run = function(action)
        if action == "test" then
          require("toggleterm").exec("./gradlew test", 1)
        elseif action == "organize-imports" then
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
      kotlin
    ];

    # JetBrains' server. Its binary is installed by modules/home/languages,
    # under the `intellij-server` name lspconfig runs.
    lsp.servers.kotlin_lsp = {
      enable = true;
      package = null;
    };

    conform-nvim.settings.formatters_by_ft = {
      kotlin = [ "ktlint" ];
    };
  };
}
