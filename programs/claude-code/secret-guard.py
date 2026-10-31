"""PreToolUse hook: block a Bash command that obviously reads a protected secret.

This is protection against accidental reads, not a security boundary. Every
script a session runs (qa-node included) can read the variable and the file it
names, so no filter over command text can stop a session set on reading it.
The guard catches the obvious shell routes so a careless command is stopped
and the model is told why.

The secret files a session gets as a path (never a value) are passed as one
JSON argument: {"paths": [...], "vars": [...]}, the decrypted files and the
environment variables holding their paths. A command exits 2, which makes
Claude Code block the call and show stderr to the model, when its text:

- names a protected file's directory (`/run/secrets`, which also covers the
  `/run/secrets.d/<n>` it resolves to) or its basename as a word,
- expands a protected variable ($VAR or ${VAR...}),
- or runs `printenv` or `env` inside $(...) or backticks, which turns the path
  into an argument.

The text is matched as a whole, heredoc bodies included, because a script
written from a heredoc can read the file as well as a `cat` can. Naming a
variable outside a substitution (`printenv VAR >/dev/null`, the availability
check) shows only the path and is allowed. Everything else exits 0, including
any input this script does not understand: the guard fails open, and the Read
deny rules beside it still hold.
"""

import json
import os
import re
import sys

HINT = (
    "Blocked: this command names a secret file, its directory or the variable "
    "holding its path. Never read it from a shell; pass the path to the "
    "program that needs it, which reads the variable itself (qa-wallet reads "
    "QA_EVM_KEY_FILE)."
)

ENV_IN_SUBSTITUTION = re.compile(r"(\$\(|`)\s*(printenv|env)(?![A-Za-z0-9_-])")


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
    return any(
        [
            any(names_file(command, path) for path in paths),
            any(expands(command, var) for var in variables),
            ENV_IN_SUBSTITUTION.search(command) is not None,
        ]
    )


def names_file(command: str, path: str) -> bool:
    directory, basename = os.path.split(path)
    return directory in command or as_word(basename).search(command) is not None


def expands(command: str, var: str) -> bool:
    return (
        re.search(r"\$\{?" + re.escape(var) + r"(?![A-Za-z0-9_])", command) is not None
    )


def as_word(text: str) -> re.Pattern[str]:
    return re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(text) + r"(?![A-Za-z0-9_.-])")


main()
