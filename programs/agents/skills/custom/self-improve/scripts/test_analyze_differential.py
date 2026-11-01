"""`label` and `check_key` against the same functions fed shfmt's reading of a command.

The analyzer reads Bash with a few regexes, so it stays a single stdlib file. Here
`bash_commands.parse`, which is real shfmt in `python-tests`, supplies the words of
each simple command and the analyzer's own `step` classifies them, so what differs
is how the command was read and nothing else. Outputs are compared, never the steps.
"""

import analyze
import pytest
from bash_commands import Parsed, Unparsable, parse
from bash_corpus import PARSED

REALISTIC = [
    "just check",
    "nix flake check",
    "nix develop -c just check",
    "nix develop .#ci -c just check",
    "nix build --no-link .#checks.x86_64-linux.typos",
    "nix run .#test -- Lexer",
    "nix run .#quick-typecheck",
    "git -C /repo status --short",
    "git add -N new.py && git commit -m 'Add new: a; b'",
    "git commit -m \"$(cat <<'EOF'\nFix the parser\n\njust check is green\nEOF\n)\"",
    'git commit -m "docs\n\njust check\n"',
    "gh pr create --title 'Fix' --body-file /tmp/body.md",
    "gh pr create --title Fix --body \"$(cat <<'EOF'\n## What\nnix flake check\nEOF\n)\"",
    "gh pr checks 12 --watch",
    "gh pr view 12 --json number -q .number",
    "rg -n 'foo|bar' src | head -20",
    "grep -E 'a|b' file.txt | wc -l",
    "sed -n '10,20p' file.py",
    "cat README.md",
    "ls -la && pwd",
    "cd /repo && just test 2>&1 | tail -20",
    "cd /repo && just check > /tmp/out.log 2>&1",
    "just check &> /tmp/out.log",
    "just test | tee /tmp/out.log",
    "just build && just test",
    "just lint; just test",
    "just check || echo failed",
    "timeout 590 just check",
    "FOO=1 BAR=2 just test",
    "env FOO=1 cabal test",
    "cabal build all",
    "cargo clippy --all-targets",
    "cargo test -p foo -- --nocapture",
    "npm test",
    "npm run lint",
    "pnpm run build",
    "pnpm test",
    "python3 - <<'PY'\nimport json\nprint(json.dumps({}))\nPY",
    "python3 -c 'import sys; print(sys.version)'",
    "cat > notes <<'EOF'\nnix flake check\nEOF",
    "cat <<-EOF > f\n\tjust check\n\tEOF\necho done",
    "if just check; then echo ok; else echo no; fi",
    "if [ -f flake.nix ]; then nix flake check; fi",
    "[[ -f flake.nix ]] && nix flake check",
    "for i in 1 2 3; do just test; done",
    'for f in *.py; do ruff check "$f"; done',
    'while read -r f; do echo "$f"; done < list.txt',
    "until gh pr checks 12; do sleep 30; done",
    "while ! just test; do sleep 5; done",
    "! just lint",
    "(cd sub && just check)",
    "{ just test; just lint; } 2>&1 | tail",
    "just \\\n  check",
    "nix develop .#ci \\\n  -c just check",
    "just check &",
    "just test & just lint & wait",
    "sleep 5 && gh pr checks 12",
    "curl -s 'https://example.com/a?x=1&y=2' | jq .",
    "git log --oneline -5 | cat",
    "# run the suite; just check next\njust test",
    "# don't skip this\njust check; echo 'done'",
    "git diff --stat origin/main...HEAD",
    "xargs -n1 echo < list.txt",
    "mkdir -p out && touch out/a",
    "rm -rf build; just build",
]

SUBSTITUTION = "A statistic of top-level commands: reading `$(...)` needs real nesting."
LEADING_REDIRECT = "Nobody writes a redirect first, and it costs only a label."
ARITHMETIC = "`(( ))` holds no command, and only the label of a rare form is off."
QUOTED_NAME = "A quoted command name is obfuscation, not what an agent writes."
QUOTES_KEPT = "The key keeps the source's quotes: still one stable key per check."

# Where the two readings differ on purpose. An entry that stops differing fails.
ALLOWED_DIFFERENCES = {
    "x=$(gh pr checks 1)": SUBSTITUTION,
    "tee >(gzip > a.gz) < in": SUBSTITUTION,
    'for f in $(seq 3); do cat "$f"; done': SUBSTITUTION,
    'pr=$(gh pr view --json number -q .number); gh pr ready "$pr"': SUBSTITUTION,
    'echo "$(git rev-parse HEAD)"': SUBSTITUTION,
    "A=1 >f cat": LEADING_REDIRECT,
    "2>/dev/null cat f": LEADING_REDIRECT,
    ">out cat f": LEADING_REDIRECT,
    "(( i > 0 )) && echo y": ARITHMETIC,
    "sle\\\nep 60": QUOTED_NAME,
    'ec"ho" hi': QUOTED_NAME,
    "e\\cho hi": QUOTED_NAME,
    'nix run .#test -- --match "Lexer basics"': QUOTES_KEPT,
}

CORPUS = [command for group in PARSED.values() for command, _ in group]
AGREEING = sorted((set(CORPUS) | set(REALISTIC)) - set(ALLOWED_DIFFERENCES))


def by_regex(command: str) -> tuple[str, str]:
    return analyze.label(command), analyze.check_key(command)


def by_shfmt(command: str) -> tuple[str, str]:
    match parse(command):
        case Parsed(commands):
            found = [analyze.step(list(simple.words)) for simple in commands]
            steps = [step for step in found if step is not None]
            return analyze.label_of(command, steps), analyze.key_of(steps)
        case Unparsable(reason):
            pytest.fail(f"shfmt cannot read {command!r}: {reason}")


@pytest.mark.parametrize("command", AGREEING)
def test_label_and_check_key_read_a_command_as_shfmt_does(command: str) -> None:
    assert by_regex(command) == by_shfmt(command)


@pytest.mark.parametrize("command", list(ALLOWED_DIFFERENCES))
def test_an_allowed_difference_still_differs(command: str) -> None:
    assert by_regex(command) != by_shfmt(command)
