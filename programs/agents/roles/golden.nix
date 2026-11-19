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
    skills = [ "engineer" ];
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
      "topics/engineering.md"
      "topics/fuel.md"
    ];
  };
  fixer = {
    capabilities = [
      "read"
      "edit"
      "shell"
    ];
    skills = [ ];
    operations = [ ];
    prose = [
      "shared/building.md"
      "topics/engineering.md"
    ];
  };
  implementer = {
    capabilities = [
      "read"
      "edit"
      "shell"
    ];
    skills = [ ];
    operations = [ ];
    prose = [
      "shared/building.md"
      "topics/engineering.md"
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
    skills = [ "refactor" ];
    operations = [ ];
    prose = [
      "shared/building.md"
      "topics/engineering.md"
      "topics/fuel.md"
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
    prose = [
      "topics/engineering.md"
      "topics/fuel.md"
    ];
  };
  reviewer = {
    capabilities = [
      "read"
      "shell"
    ];
    skills = [ ];
    operations = [ ];
    prose = [
      "topics/engineering.md"
      "topics/fuel.md"
    ];
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
      "topics/engineering.md"
      "topics/fuel.md"
    ];
  };
}
