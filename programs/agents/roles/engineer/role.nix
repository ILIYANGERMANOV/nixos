# long: it waits on its workers for many minutes, and each wake would otherwise
# rewrite its whole context.
{ role }:
{
  description = "Delivers one task as a PR with the preloaded engineer skill. Its prompt names a brief file.";
  instructions = [ (role ./role.md) ];
  cache = "long";
}
