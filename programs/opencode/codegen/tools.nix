# OpenCode 1.19.5's tools by their vendor-free name (programs/agents/hooks'
# vocabulary.json, every name but `other`): the one table a role's
# `permission`, the AGENTS.md glossary and the hook adapter read.
#
#   tools      - the tool ids a hook sees
#   permission - the V1 permission keys a role with that capability is
#                allowed. write and edit share `edit`. glob and grep search
#                what `read` reads, so a role that may read may search.
#
# null: OpenCode has no such tool. A subagent's last reply is its hand-back,
# and no agent can stop another.
{
  shell = {
    tools = [ "bash" ];
    permission = [ "bash" ];
  };
  read = {
    tools = [ "read" ];
    permission = [
      "read"
      "glob"
      "grep"
    ];
  };
  edit = {
    tools = [ "edit" ];
    permission = [ "edit" ];
  };
  write = {
    tools = [ "write" ];
    permission = [ "edit" ];
  };
  web = {
    tools = [
      "webfetch"
      "websearch"
    ];
    permission = [
      "webfetch"
      "websearch"
    ];
  };
  delegate = {
    tools = [ "task" ];
    permission = [ "task" ];
  };
  skill = {
    tools = [ "skill" ];
    permission = [ "skill" ];
  };
  handback = null;
  stopAgent = null;
}
