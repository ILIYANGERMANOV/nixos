# The nine role records as they were written by hand before stage A (#360 call
# 17), plus their `operations`: lib/derive.nix's derivation must equal them.
# A change here is a reviewed change to what a role may do.
{
  checker = {
    capabilities = [
      "read"
      "shell"
    ];
    skills = [ ];
    operations = [ ];
    prose = [ ];
  };
  engineer = {
    capabilities = [
      "read"
      "edit"
      "shell"
      "web"
      "delegate"
      "skill"
    ];
    skills = [
      "engineer"
      "engineering"
    ];
    operations = [
      "ask"
      "await"
      "notify"
      "spawn:checker"
      "spawn:fixer"
      "spawn:implementer"
      "spawn:refactorer"
      "spawn:researcher"
      "spawn:review-lead"
    ];
    prose = [
      "topics/trivial.md"
      "topics/quality.md"
    ];
  };
  fixer = {
    capabilities = [
      "read"
      "edit"
      "shell"
    ];
    skills = [ "engineering" ];
    operations = [ ];
    prose = [ "shared/building.md" ];
  };
  implementer = {
    capabilities = [
      "read"
      "edit"
      "shell"
    ];
    skills = [ "engineering" ];
    operations = [ ];
    prose = [
      "shared/building.md"
      "topics/quality.md"
    ];
  };
  qa-runner = {
    capabilities = [
      "read"
      "edit"
      "shell"
      "web"
    ];
    skills = [ ];
    operations = [ ];
    prose = [ ];
  };
  refactorer = {
    capabilities = [
      "read"
      "edit"
      "shell"
    ];
    skills = [
      "refactor"
      "engineering"
    ];
    operations = [ ];
    prose = [
      "shared/building.md"
      "topics/quality.md"
    ];
  };
  researcher = {
    capabilities = [
      "read"
      "shell"
      "web"
    ];
    skills = [ "researcher" ];
    operations = [ ];
    prose = [ "topics/quality.md" ];
  };
  reviewer = {
    capabilities = [
      "read"
      "shell"
    ];
    skills = [ ];
    operations = [ ];
    prose = [ "topics/quality.md" ];
  };
  review-lead = {
    capabilities = [
      "read"
      "shell"
      "delegate"
    ];
    skills = [ "pragmatic-review" ];
    operations = [ "spawn:reviewer" ];
    prose = [
      "topics/trivial.md"
      "topics/quality.md"
    ];
  };
}
