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
      };
      keymaps = {
        "<leader>fg" = "live_grep_args";
      };
    };
  };

  extraPackages = [
    pkgs.ripgrep
    pkgs.fd
  ];
}
