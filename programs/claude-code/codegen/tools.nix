# Claude Code's tools by their vendor-free name (programs/agents/hooks'
# vocabulary.json): the one table a role's `tools:` list, a hook's matcher and
# the hook adapter all read.
{
  shell = [ "Bash" ];
  read = [ "Read" ];
  edit = [ "Edit" ];
  write = [ "Write" ];
  web = [
    "WebFetch"
    "WebSearch"
  ];
  delegate = [ "Agent" ];
  handback = [ "SubagentHandback" ];
  ask = [ "AskUserQuestion" ];
  skill = [ "Skill" ];
}
