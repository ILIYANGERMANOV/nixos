# The subagent definitions every flavor installs: the catalog, its farm and its
# check. A definition is the `<name>.md` Claude Code reads from ~/.claude/agents.
{
  pkgs,
  lib ? pkgs.lib,
  skillNames,
  frontmatter,
}:

let
  all = {
    # Overrides the built-in, which callers use for nearly every spawn, to drop
    # the MCP schemas. `disallowedTools` only: a `tools:` list would silently
    # take `Skill` too, and with it the skill listing every implementer needs.
    general-purpose = ./general-purpose.md;
    researcher = ./researcher.md;
  };

  # Every field Claude Code documents for a subagent. It ignores a misspelled
  # one, and a misspelled `disallowedTools` would quietly put MCP back.
  fields = [
    "name"
    "description"
    "tools"
    "disallowedTools"
    "model"
    "permissionMode"
    "mcpServers"
    "hooks"
    "maxTurns"
    "autoCompactWindow"
    "skills"
    "initialPrompt"
    "memory"
    "effort"
    "background"
    "omitClaudeMd"
    "isolation"
  ];

  # subagent-lint <definition.md> <file of known skill names, one per line>
  lint = pkgs.writeShellApplication {
    name = "subagent-lint";
    runtimeInputs = [
      pkgs.gawk
      pkgs.yq-go
    ];
    text = ''
      md="$1" known="$2"
      fields=" ${toString fields} "
      name=$(basename "$md" .md)
      ${frontmatter}

      die() {
        echo "  x $name: $1" >&2
        exit 1
      }

      [ "$(head -n 1 "$md")" = "---" ] || die "does not open with a YAML frontmatter block"
      fm=$(frontmatter "$md")

      [ "$(yq -r '.name // ""' <<<"$fm")" = "$name" ] || die "frontmatter name differs from the file name"
      [ -n "$(yq -r '.description // ""' <<<"$fm")" ] || die "frontmatter is missing 'description'"

      for field in $(yq -r 'keys | .[]' <<<"$fm"); do
        case "$fields" in
          *" $field "*) ;;
          *) die "unknown frontmatter field '$field'" ;;
        esac
      done

      if [ "$name" = general-purpose ] && [ "$(yq 'has("tools")' <<<"$fm")" = true ]; then
        die "a tools list silently drops Skill, use disallowedTools only"
      fi

      for skill in $(yq -r '.skills // [] | .[]' <<<"$fm"); do
        grep -qxF "$skill" "$known" || die "preloads '$skill', which is not in the skill catalog"
      done
    '';
  };

  # A definition each rule must reject, proving the rule can fail.
  rejected = {
    general-purpose = ''
      ---
      name: general-purpose
      description: Gained a tools list.
      tools: Read
      ---
    '';
    no-description = ''
      ---
      name: no-description
      ---
    '';
    other-name = ''
      ---
      name: not-the-file-name
      description: The name differs from the file.
      ---
    '';
    typo = ''
      ---
      name: typo
      description: A misspelled field.
      disallowedTool: mcp__*
      ---
    '';
    unknown-skill = ''
      ---
      name: unknown-skill
      description: Preloads a skill outside the catalog.
      skills:
        - no-such-skill
      ---
    '';
  };
in
{
  inherit all;

  # A store directory of `<name>.md` links, for ~/.claude/agents.
  farm = pkgs.linkFarm "claude-agents" (
    lib.mapAttrsToList (name: path: {
      name = "${name}.md";
      inherit path;
    }) all
  );

  check =
    pkgs.runCommand "subagents-check"
      {
        nativeBuildInputs = [ lint ];
        known = lib.concatLines skillNames;
        passAsFile = [ "known" ];
      }
      ''
        mkdir bad
        ${lib.concatStrings (
          lib.mapAttrsToList (name: path: ''
            cp ${path} ${name}.md
            subagent-lint ${name}.md "$knownPath"
          '') all
        )}
        ${lib.concatStrings (
          lib.mapAttrsToList (name: text: ''
            cat >bad/${name}.md <<'EOF'
            ${text}EOF
            if subagent-lint bad/${name}.md "$knownPath" 2>/dev/null; then
              echo "subagent-lint accepted the bad definition ${name}" >&2
              exit 1
            fi
          '') rejected
        )}
        echo "checked ${toString (lib.length (lib.attrNames all))} subagent(s)" >"$out"
      '';
}
