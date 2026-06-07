{ pkgs, ... }: {
  opts = {
    scrolloff = 10;
  };

  plugins = {
    neoscroll.enable = true;
  };

  # Note: "stay-centered-nvim" might affect performance and breaks smooth scrolling
  extraPlugins = [ pkgs.vimPlugins.stay-centered-nvim ];

  extraConfigLua = ''
    require("stay-centered").setup()
  '';
}
