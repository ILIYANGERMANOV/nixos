{ pkgs, lib, ... }:

let
  shared = import ./shared.nix { inherit lib; };
  inherit (shared) fdExcludeFlags toLuaList;

  # Ignores .gitignore so git-ignored files (e.g. .env.local) show up, but
  # still prunes the heavy directories above.
  fdNoIgnore = [
    "fd"
    "--type"
    "f"
    "--hidden"
    "--no-ignore-vcs"
  ]
  ++ fdExcludeFlags;

  # Env files anywhere in the project: .env.local, .env.example,
  # .environments/.env.beta, ... `--glob` matches the file's basename.
  fdEnv = fdNoIgnore ++ [
    "--glob"
    ".env*"
  ];

  findFiles =
    fd: "<cmd>lua require('telescope.builtin').find_files({ find_command = ${toLuaList fd} })<CR>";
in
{
  # fff owns <leader>ff and nothing else. It is a file-search specialist: no
  # `vim.ui.select` provider and no "show git-ignored files" mode, so telescope
  # keeps <leader>fa and every non-file picker.
  # See docs/adr/0003-fff-owns-file-search.md.
  #
  # Every property we want is a fff default, so this carries no `settings`:
  # cwd-scoped indexing, hidden-but-not-ignored files (it only skips dotfiles
  # outside a git root), an 0.8x0.8 dialog with a preview, and `middle` path
  # shortening that keeps both the top-level directory and the filename.
  #
  # That matters more than usual here: the nixvim fff module is freeform (no
  # `settingsOptions`), so a misspelled key is silently ignored rather than
  # failing the build - and its `settingsExample` is stale against the pinned
  # 0.8.4 (it shows `key_bindings`/`select_file`; conf.lua reads
  # `keymaps`/`select`). Passing nothing sidesteps both traps.
  #
  # Searching: a plain query is fuzzy (`useViewModel` finds
  # useLoginViewModel.ts). A query containing a glob metacharacter switches to
  # glob mode, where the pattern is anchored to the WHOLE relative path and `*`
  # crosses `/` - so it is `*use*ViewModel*`, not `use*ViewModel`. `**` and
  # brace expansion work: `src/**/*.{ts,tsx}`.
  plugins.fff.enable = true;

  keymaps = [
    {
      mode = "n";
      key = "<leader>ff";
      action = "<cmd>lua require('fff').find_files()<CR>";
      options.desc = "Find Files (fff, frecency-ranked)";
    }
    {
      mode = "n";
      key = "<leader>fa";
      action = findFiles fdNoIgnore;
      options.desc = "Find All Files (Hidden + Ignored)";
    }
    {
      mode = "n";
      key = "<leader>fe";
      action = findFiles fdEnv;
      options.desc = "Find Env Files (.env*)";
    }
    {
      mode = "n";
      key = "<leader>fr";
      action = "<cmd>lua require('telescope.builtin').oldfiles({ cwd_only = true })<CR>";
      options.desc = "Find Recent Files (this project)";
    }
  ];

  extraConfigLua = ''
    -- fff hardcodes dark-tuned hexes for its git-status groups
    -- (highlights.lua:169). The `highlight default link ... GitSignsAdd`
    -- fallback it writes directly below them never fires, because `highlight
    -- default` does not overwrite a group that is already defined - so the
    -- hex wins and emerald/amber wash out on catppuccin latte.
    --
    -- Re-link them for real. catppuccin themes GitSigns* correctly in both
    -- latte and mocha, so this needs no light/dark branching and no hardcoded
    -- colour. A plain (non-`default`) set_hl outranks fff's, in either order.
    local function _set_fff_git_hl()
      local targets = {
        Staged = "GitSignsAdd",
        Untracked = "GitSignsAdd",
        Modified = "GitSignsChange",
        Renamed = "GitSignsChange",
        Deleted = "GitSignsDelete",
        Ignored = "Comment",
      }
      -- The selected row cannot use a link: fff paints it as fg-on-Visual, so
      -- the colour has to be resolved and re-applied rather than inherited.
      local visual_bg = vim.api.nvim_get_hl(0, { name = "Visual", link = false }).bg
      for state, target in pairs(targets) do
        vim.api.nvim_set_hl(0, "FFFGit" .. state, { link = target })
        vim.api.nvim_set_hl(0, "FFFGitSign" .. state, { link = target })
        local fg = vim.api.nvim_get_hl(0, { name = target, link = false }).fg
        if fg then
          vim.api.nvim_set_hl(0, "FFFGitSign" .. state .. "Selected", { fg = fg, bg = visual_bg })
        end
      end
    end
    _set_fff_git_hl()
    -- A colorscheme reload clears every group, so re-apply on the way out.
    vim.api.nvim_create_autocmd("ColorScheme", { pattern = "*", callback = _set_fff_git_hl })
  '';

  extraPackages = [
    pkgs.fd
  ];
}
