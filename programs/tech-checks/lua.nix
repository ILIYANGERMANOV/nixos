# The Lua in Nix strings under programs/nvim: selene and stylua, until #261 moves
# it to real files. The fragments come from evaluating the modules, not from
# parsing text, so a Nix interpolation is rendered and a `''` escape resolved.
# `check.nix` is outside this: it is test code, and builds nixvim to evaluate.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Floors at and just under today's count: below either the walk has lost something,
  # whatever the markers say. Removing Lua on purpose means lowering them.
  minimumFragments = 47;
  minimumLines = 480;

  fragments = fragmentsOfModule ../nvim;

  # What a module would hand nixvim. Nothing is merged, so `style` only has to
  # exist: a `lib.mkIf` condition is never forced, which is what reaches the Lua
  # of every theme at once.
  loadModule =
    file:
    let
      module = import file;
    in
    if lib.isFunction module then
      module {
        inherit pkgs lib;
        root = ../..;
        config.myNixVim.style = "auto";
      }
    else
      module;

  fragmentsOfModule =
    path:
    let
      file = if lib.pathIsDirectory path then lib.path.append path "default.nix" else path;
      module = loadModule file;
    in
    fragmentsOfValue file "" (removeAttrs module [ "imports" ])
    ++ lib.concatMap fragmentsOfModule (module.imports or [ ]);

  fragmentsOfValue =
    file: key: value:
    let
      recurse = fragmentsOfValue file;
    in
    if lib.isDerivation value then
      [ ]
    else if lib.isList value then
      lib.concatMap (recurse key) value
    else if lib.isAttrs value then
      {
        "if" = recurse key value.content or null;
        override = recurse key value.content or null;
        merge = recurse key value.contents or null;
        option = [ ];
        plain = lib.concatLists (lib.mapAttrsToList recurse value);
      }
      .${value._type or "plain"}
    else if lib.isFunction value then
      throw "lua-lint: `${key}` in ${toString file} is a function, which hides any Lua it returns"
    else if lib.isString value then
      lib.optional (classify key value != null) ({ inherit file; } // classify key value)
    else
      [ ];

  # A `command` is a keymap's right-hand side, and an `expression` is what nixvim
  # splices after `=`, so it needs `return` to parse on its own.
  classify =
    key: text:
    let
      command = builtins.match "<cmd>lua (.*)<CR>" text;
      chunk = {
        kind = "scripts";
        lua = text;
      };
      expression = {
        kind = "scripts";
        lua = "return ${text}";
      };
    in
    if lib.hasPrefix "extraConfigLua" key then
      chunk
    else if key == "__raw" then
      expression
    else if command != null then
      {
        kind = "commands";
        lua = lib.head command;
      }
    else if lib.hasInfix "<cmd>lua " text then
      throw "lua-lint: cannot read the keymap `${text}`"
    else if looksLikeLua text then
      expression
    else
      null;

  # Plugin settings take Lua in a plain string, under a key nothing marks. Any
  # call counts: a `desc` has a space before its parenthesis, and a wrong guess
  # fails the parse instead of passing.
  looksLikeLua = text: lib.length (builtins.split "[[:alnum:]_]\\(|vim\\." text) > 1;

  # A marker in a source the walk got nothing from: an unimported file, or a
  # value it cannot see into. Helpers render one marker several times, so a file
  # may yield more fragments than it has markers, never fewer.
  missed = lib.filter (file: markersIn file > lib.count (f: f.file == file) fragments) sources;

  sources = lib.fileset.toList (
    lib.fileset.fileFilter (file: file.hasExt "nix" && file.name != "check.nix") ../nvim
  );

  markersIn =
    file:
    lib.count lib.isList (
      builtins.split "extraConfigLua(Pre|Post)?[[:space:]]*=|__raw[[:space:]]*=|<cmd>lua " (
        builtins.readFile file
      )
    );

  lines = lib.foldl' (sum: f: sum + lib.length (lib.splitString "\n" (lib.trim f.lua))) 0 fragments;

  # `<kind>/<source>-<n>.lua`, so a finding names the file to fix.
  fragmentFiles = pkgs.linkFarm "lua-fragments" (
    lib.imap0 (i: fragment: {
      name = "${fragment.kind}/${sourceName fragment.file}-${toString i}.lua";
      path = pkgs.writeText "fragment.lua" "${lib.trim fragment.lua}\n";
    }) fragments
  );

  sourceName =
    file:
    lib.replaceStrings [ "/" ] [ "-" ] (
      lib.removeSuffix ".nix" (lib.removePrefix "./" (lib.path.removePrefix ../nvim file))
    );

  config = lib.fileset.toSource {
    root = ./lua-config;
    fileset = ./lua-config;
  };
in
{
  # A command stays out of stylua: a keymap holds one line, so there is no layout
  # to check, and `find_command` renders far past the column limit.
  lua-lint =
    assert lib.assertMsg (missed == [ ]) "lua-lint: Lua the walk missed in ${toString missed}";
    assert lib.assertMsg (lib.length fragments >= minimumFragments)
      "lua-lint: found ${toString (lib.length fragments)} fragments, expected ${toString minimumFragments}";
    assert lib.assertMsg (
      lines >= minimumLines
    ) "lua-lint: found ${toString lines} lines of Lua, expected ${toString minimumLines}";
    pkgs.runCommand "lua-lint"
      {
        nativeBuildInputs = [
          pkgs.selene
          pkgs.stylua
        ];
      }
      ''
        cp -rL ${fragmentFiles}/. .
        cp ${config}/* .
        selene --no-summary --color Never scripts commands
        stylua --check --config-path stylua.toml scripts
        echo "lua-lint: ${toString (lib.length fragments)} fragments, ${toString lines} lines"
        touch "$out"
      '';
}
