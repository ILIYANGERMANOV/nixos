{ lib, ... }:

let
  shared = import ./shared.nix { inherit lib; };
in
{
  imports = [
    ./file.nix
    ./grep.nix
  ];

  keymaps = [
    # Reopen the previous picker with its query and results intact. Telescope
    # only - it never resumes an fff picker, and the pinned fff (0.8.4) has no
    # resume of its own, so <leader>ff always starts fresh.
    {
      mode = "n";
      key = "<leader>fl";
      action = "<cmd>Telescope resume<CR>";
      options.desc = "Resume Last Search";
    }
    {
      mode = "n";
      key = "<leader>nh";
      action = "<cmd>noh<CR>";
      options.desc = "Clear Highlights";
    }
  ];

  # Engine-level telescope config: the parts that belong to neither ./file.nix
  # nor ./grep.nix because they apply to every picker.
  plugins.telescope = {
    enable = true;

    # Derived from the one `excludeDirs` list in ./shared.nix, so this can
    # never drift from the `fd --exclude` flags the file pickers use.
    settings.defaults.file_ignore_patterns = shared.ignorePatterns;

    extensions = {
      ui-select.enable = true;
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
  };
}
