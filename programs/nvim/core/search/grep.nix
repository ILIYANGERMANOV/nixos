{ pkgs, ... }:

{
  keymaps = [
    # Grep the word under the cursor (normal) or the visual selection.
    # Opens live_grep_args pre-filled, so you can still append rg flags
    # (e.g. ` -t ts`, ` -g '!*test*'`) to narrow it down.
    {
      mode = "n";
      key = "<leader>fw";
      action = "<cmd>lua require('telescope-live-grep-args.shortcuts').grep_word_under_cursor()<CR>";
      options.desc = "Grep Word Under Cursor";
    }
    {
      mode = "x";
      key = "<leader>fw";
      action = "<cmd>lua require('telescope-live-grep-args.shortcuts').grep_visual_selection()<CR>";
      options.desc = "Grep Visual Selection";
    }
    {
      mode = "n";
      key = "<leader>ss";
      action = "<cmd>Telescope current_buffer_fuzzy_find<CR>";
      options.desc = "Search in Buffer";
    }
  ];

  plugins.telescope = {
    # Base ripgrep command for ALL grep pickers (live_grep_args, grep_string,
    # ...). This mirrors telescope's built-in default and only adds the last
    # two flags:
    #   --color=never : telescope parses rg's PLAIN text and does its own match
    #                   highlighting; color escape codes would corrupt that
    #                   parse. (Not a UI change - results stay colored.)
    #   --hidden      : also search dotfiles/dotfolders (.github/, .env*).
    #   --glob=!.git  : but keep the .git directory out.
    # node_modules and build output are still skipped: rg honours .gitignore,
    # and `file_ignore_patterns` in ./default.nix prunes the rest.
    settings.defaults.vimgrep_arguments = [
      "rg"
      "--color=never"
      "--no-heading"
      "--with-filename"
      "--line-number"
      "--column"
      "--smart-case"
      "--hidden"
      "--glob=!.git"
    ];

    extensions.live-grep-args.enable = true;

    keymaps = {
      "<leader>fd" = "live_grep_args";
      "<leader>fg" = "live_grep_args";
    };
  };

  extraPackages = [
    pkgs.ripgrep
  ];
}
