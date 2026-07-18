{ pkgs, lib, ... }:

let
  # Directories fd should never even descend into. Pruning at traversal time
  # (vs. telescope filtering results after the fact) is what keeps the pickers
  # instant in large JS/Nix repos. `.direnv` matters here specifically because
  # nix-direnv drops big GC-root trees into every project.
  excludeDirs = [
    "node_modules"
    ".git"
    ".direnv"
    "dist"
    "build"
    "target"
    ".next"
    "coverage"
  ];
  excludeFlags = lib.concatMap (d: [ "--exclude" d ]) excludeDirs;

  # Render a Nix list of strings as a Lua array literal: { "a", "b" }
  toLuaList = xs: "{ " + lib.concatStringsSep ", " (map (x: ''"${x}"'') xs) + " }";

  # Respects .gitignore (fd's default), just hardened with explicit excludes
  # for repos that lack a .gitignore.
  fdRespect = [ "fd" "--type" "f" "--hidden" ] ++ excludeFlags;

  # Ignores .gitignore so git-ignored files (e.g. .env.local) show up, but
  # still prunes the heavy directories above.
  fdNoIgnore = [ "fd" "--type" "f" "--hidden" "--no-ignore-vcs" ] ++ excludeFlags;

  # Env files anywhere in the project: .env.local, .env.example,
  # .environments/.env.beta, ... `--glob` matches the file's basename.
  fdEnv = fdNoIgnore ++ [ "--glob" ".env*" ];

  findFiles = fd: ''<cmd>lua require('telescope.builtin').find_files({ find_command = ${toLuaList fd} })<CR>'';
in
{
  keymaps = [
    {
      mode = "n";
      key = "<leader>ff";
      action = "<cmd>Telescope frecency workspace=CWD<CR>";
      options.desc = "Find Files (Frecency-ranked)";
    }
    {
      mode = "n";
      key = "<leader>fF";
      action = findFiles fdRespect;
      options.desc = "Find Files (unranked, respects .gitignore)";
    }
    {
      mode = "n";
      key = "<leader>fr";
      action = "<cmd>lua require('telescope.builtin').oldfiles({ cwd_only = true })<CR>";
      options.desc = "Find Recent Files (this project)";
    }
    {
      mode = "n";
      key = "<leader>fe";
      action = findFiles fdEnv;
      options.desc = "Find Env Files (.env*)";
    }
    {
      mode = "n";
      key = "<leader>fa";
      action = findFiles fdRespect;
      options.desc = "Find All Files (Hidden but not Ignored)";
    }
    {
      mode = "n";
      key = "<leader>fA";
      action = findFiles fdNoIgnore;
      options.desc = "Find All Files (Hidden + Ignored)";
    }
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
    # Reopen the previous picker with its query and results intact.
    {
      mode = "n";
      key = "<leader>fl";
      action = "<cmd>Telescope resume<CR>";
      options.desc = "Resume Last Search";
    }
    {
      mode = "n";
      key = "<leader>ss";
      action = "<cmd>Telescope current_buffer_fuzzy_find<CR>";
      options.desc = "Search in Buffer";
    }
    {
      mode = "n";
      key = "<leader>nh";
      action = "<cmd>noh<CR>";
      options.desc = "Clear Highlights";
    }
  ];

  plugins = {
    telescope = {
      enable = true;
      settings.defaults = {
        # Base ripgrep command for ALL grep pickers (live_grep_args,
        # grep_string, ...). This mirrors telescope's built-in default and only
        # adds the last two flags:
        #   --color=never : telescope parses rg's PLAIN text and does its own
        #                   match highlighting; color escape codes would corrupt
        #                   that parse. (Not a UI change — results stay colored.)
        #   --hidden      : also search dotfiles/dotfolders (.github/, .env*).
        #   --glob=!.git  : but keep the .git directory out.
        # node_modules and build output are still skipped: rg honours .gitignore.
        vimgrep_arguments = [
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
        file_ignore_patterns = [
          "^node_modules/"
          "^.git/"
          "^dist/"
          "^build/"
          "target/"
        ];
      };
      extensions = {
        live-grep-args.enable = true;
        ui-select.enable = true;
        frecency.enable = true;
        # Compiled sorter: faster fuzzy matching on large result sets and
        # unlocks fzf query syntax in every prompt:
        #   'exact   ^prefix   suffix$   !negate   foo | bar
        fzf-native = {
          enable = true;
          settings = {
            fuzzy = true;
            override_generic_sorter = true;
            override_file_sorter = true;
            case_mode = "smart_case";
          };
        };
      };
      keymaps = {
        "<leader>fd" = "live_grep_args";
        "<leader>fg" = "live_grep_args";
      };
    };
  };

  extraPackages = [
    pkgs.ripgrep
    pkgs.fd
  ];
}
