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

  fragmentsOfModule =
    path:
    let
      file = if lib.pathIsDirectory path then lib.path.append path "default.nix" else path;
      module = loadModule file;
    in
    fragmentsOfValue file "" (removeAttrs module [ "imports" ])
    ++ lib.concatMap fragmentsOfModule (module.imports or [ ]);

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

  fragmentsOfValue =
    file: key: value:
    let
      # Everything under a Lua key is Lua, whatever its leaf is called:
      # `luaConfig.pre`, `extraFiles."x.lua".text`.
      recurse = name: fragmentsOfValue file (if isStatementsKey key then key else name);
    in
    if lib.isDerivation value then
      [ ]
    else if lib.isList value then
      lib.concatMap (recurse key) value
    else if lib.isAttrs value then
      {
        "if" = recurse key value.content;
        override = recurse key value.content;
        order = recurse key value.content;
        merge = recurse key value.contents;
        option = [ ];
        plain = lib.concatLists (lib.mapAttrsToList recurse value);
      }
      .${value._type or "plain"}
    else if lib.isFunction value then
      throw "lua-lint: `${key}` in ${toString file} is a function, which hides any Lua it returns"
    else if lib.isString value then
      map (fragment: fragment // { inherit file; }) (classify key (lib.trim value))
    else
      [ ];

  # A `command` is a keymap's right-hand side, and an `expression` is what nixvim
  # splices after `=`, so it needs `return` to parse on its own. `marked` says
  # the source text holds a marker for it, which is what `missed` counts.
  classify =
    key: text:
    let
      command = builtins.match "<[cC][mM][dD]>lua (.*)<[cC][rR]>" text;
      fragment = kind: marked: lua: [ { inherit kind marked lua; } ];
      expression = marked: fragment "scripts" marked "return ${text}";
    in
    if isStatementsKey key then
      fragment "scripts" true text
    else if key == "__raw" then
      expression true
    else if command != null then
      fragment "commands" true (lib.head command)
    else if lib.hasInfix "<cmd>lua " (lib.toLower text) then
      throw "lua-lint: cannot read the keymap `${text}`"
    else if looksLikeLua text then
      expression false
    else
      [ ];

  isStatementsKey = key: builtins.match "extraConfigLua.*|luaConfig|onAttach|extraFiles" key != null;

  # Plugin settings take Lua in a plain string, under a key nothing marks. Any
  # call counts: a `desc` has a space before its parenthesis, and a wrong guess
  # fails the parse instead of passing.
  looksLikeLua = text: occurrences "[[:alnum:]_]\\(|function[[:space:]]*\\(|vim\\." text > 0;

  occurrences = pattern: text: lib.count lib.isList (builtins.split pattern text);

  # A marker the walk got nothing from: an unimported file, or a value it cannot
  # see into, such as `lib.optionalAttrs stdenv.isDarwin` on Linux. So each file's
  # marked fragments must equal its markers exactly: any surplus would hide a
  # miss. A helper renders one marker per call, and `helperRenders` names the rest.
  missed = lib.filter (
    file:
    markersIn file + helperRenders.${relative file} or 0
    != lib.count (f: f.file == file && f.marked) fragments
  ) sources;

  helperRenders = {
    "./core/search/file.nix" = 1;
    "./languages/typescript.nix" = 2;
  };

  sources = lib.fileset.toList (
    lib.fileset.fileFilter (file: file.hasExt "nix" && file.name != "check.nix") ../nvim
  );

  markersIn =
    file:
    occurrences "extraconfiglua(pre|post)?[[:space:]]*=|luaconfig|onattach|extrafiles|__raw[[:space:]]*=|<cmd>lua " (
      lib.toLower (builtins.readFile file)
    );

  lines = lib.foldl' (sum: f: sum + lib.length (lib.splitString "\n" f.lua)) 0 fragments;

  # `<kind>/<source>-<n>.lua`, so a finding names the file to fix.
  fragmentFiles = pkgs.linkFarm "lua-fragments" (
    lib.imap0 (i: fragment: {
      name = "${fragment.kind}/${sourceName fragment.file}-${toString i}.lua";
      path = pkgs.writeText "fragment.lua" "${fragment.lua}\n";
    }) fragments
  );

  sourceName =
    file:
    lib.replaceStrings [ "/" ] [ "-" ] (
      lib.removeSuffix ".nix" (lib.removePrefix "./" (relative file))
    );

  relative = lib.path.removePrefix ../nvim;
in
{
  lua-lint =
    assert lib.assertMsg (missed == [ ]) "lua-lint: markers and fragments differ in ${toString missed}";
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
        cp ${./lua-config}/* .
        selene --no-summary --color Never scripts commands
        stylua --check --config-path stylua.toml scripts
        # A keymap holds one line, and `find_command` renders far past the limit,
        # so a command is checked for everything but its width.
        stylua --check --config-path stylua.toml --column-width 9999 commands
        echo "lua-lint: ${toString (lib.length fragments)} fragments, ${toString lines} lines"
        touch "$out"
      '';
}
