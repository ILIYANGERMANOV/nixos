"""PreToolUse hook: block a Bash command that could read a protected secret file.

The secret files a session gets as a path (never a value) are passed as one
JSON argument: {"paths": [...], "vars": [...]}, the decrypted files and the
environment variables holding their paths. A command whose text names one of
those paths, or expands one of those variables ($VAR or ${VAR...}), exits 2,
which makes Claude Code block the call and show stderr to the model. The text
is matched as a whole, heredoc bodies included, because a script written from
a heredoc can read the file as well as a `cat` can. Naming a variable without
expanding it (`printenv VAR`) shows only the path and is allowed. Everything
else exits 0, including any input this script does not understand: the guard
fails open, and the Read deny rules beside it still hold.
"""

import json
import re
import sys

HINT = (
    "Blocked: this command names a secret file or the variable holding its "
    "path. Never read it from a shell; pass the path to the program that "
    "needs it, which reads the variable itself (qa-wallet reads "
    "QA_EVM_KEY_FILE)."
)


def main() -> None:
    try:
        protected = json.loads(sys.argv[1])
        command = json.load(sys.stdin)["tool_input"]["command"]
    except Exception:
        sys.exit(0)

    if names_secret(command, protected["paths"], protected["vars"]):
        print(HINT, file=sys.stderr)
        sys.exit(2)


def names_secret(command: str, paths: list[str], variables: list[str]) -> bool:
    if any(path in command for path in paths):
        return True
    return any(
        re.search(r"\$(\{)?" + re.escape(var) + r"(?![A-Za-z0-9_])", command)
        for var in variables
    )


main()
