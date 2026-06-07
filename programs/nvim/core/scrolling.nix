{ pkgs, ... }: {
  opts = {
    scrolloff = 10;
  };

  plugins = {
    neoscroll.enable = true;
  };

  extraPlugins = [ pkgs.vimPlugins.stay-centered-nvim ];

  extraConfigLua = ''
    require("stay-centered").setup()
  '';
}
