"""Tricky commands, for `test_bash_commands.py` to read through real shfmt and bash.

The tests judge each entry by `bash -n`, so a shfmt whose JSON changed fails the
check instead of quietly failing open in production. A guard allows on any failure
of the parser, so its own tests cannot be what notices one.
"""

from bash_commands import Loop, Simple, Sink


def cmd(words: str | tuple[str, ...], flags: str = "") -> Simple:
    """A wanted command: `words` split on spaces, or spelled out when one holds a space.

    Flags: f stdout to a file, p to a pipe, b background, n in a substitution,
    w in a `while` or `until`, o in a `for` or `select`.
    """
    return Simple(
        tuple(words.split()) if isinstance(words, str) else words,
        Sink.FILE if "f" in flags else Sink.PIPE if "p" in flags else Sink.SCREEN,
        "b" in flags,
        Loop.ON_CONDITION
        if "w" in flags
        else Loop.OVER_LIST
        if "o" in flags
        else Loop.NONE,
        "n" in flags,
    )


type Entry = tuple[str, list[Simple]]

# What bash accepts, and the commands in it, in any order.
PARSED: dict[str, list[Entry]] = {
    "heredocs": [
        ("cat <<EOF > out.txt\nhello $USER\nEOF", [cmd("cat", "f")]),
        ("python3 - <<'PY'\nimport time\ntime.sleep(60)\nPY", [cmd("python3 -")]),
        (
            "cat <<'EOF' | tee f\nsleep 60 && rm -rf /\nEOF",
            [cmd("cat", "p"), cmd("tee f")],
        ),
        ("cat <<-EOF\n\tx\n\tEOF\necho done", [cmd("cat"), cmd("echo done")]),
        ("cat <<EOF\n$(sleep 60)\nEOF", [cmd("cat"), cmd("sleep 60", "np")]),
        ("cat <<'EOF'\n$(sleep 60)\nEOF", [cmd("cat")]),
        ("cat <<\\EOF\n$(sleep 60)\nEOF", [cmd("cat")]),
        ("cat <<A <<'B'\n1\nA\n2\nB\nwc -l", [cmd("cat"), cmd("wc -l")]),
        ('cat <<<"sleep 60"', [cmd("cat")]),
        ("cat <<EOF\nEOF-not\n EOF\nEOF\nsleep 12", [cmd("cat"), cmd("sleep 12")]),
        (
            "git commit -F - <<EOF && git push\nmsg; sleep 60\nEOF",
            [cmd("git commit -F -"), cmd("git push")],
        ),
        ("tee f <<EOF &\nx\nEOF\nsleep 12", [cmd("tee f", "b"), cmd("sleep 12")]),
    ],
    "bash -c": [
        ("bash -c 'sleep 60'", [cmd(("bash", "-c", "sleep 60"))]),
        (
            'bash -lc "until true; do sleep 1; done"',
            [cmd(("bash", "-lc", "until true; do sleep 1; done"))],
        ),
        (
            "until bash -c 'true'; do :; done",
            [cmd(("bash", "-c", "true"), "w"), cmd(":", "w")],
        ),
        (
            'bash -c "nix build .\\#ci && sleep 60"',
            [cmd(("bash", "-c", "nix build .\\#ci && sleep 60"))],
        ),
        ("timeout 300 bash -c 'x; y'", [cmd(("timeout", "300", "bash", "-c", "x; y"))]),
        (
            "nix develop -c bash -c 'sleep 60' | tail -5",
            [
                cmd(("nix", "develop", "-c", "bash", "-c", "sleep 60"), "p"),
                cmd("tail -5"),
            ],
        ),
        ("bash -c 'echo \"a b\"'\\''c'", [cmd(("bash", "-c", 'echo "a b"\'c'))]),
    ],
    "hashes": [
        ("nix build .#ci && echo ok", [cmd("nix build .#ci"), cmd("echo ok")]),
        ("nix develop .#ci -c just test", [cmd("nix develop .#ci -c just test")]),
        ("echo a#b # comment\nsleep 12", [cmd("echo a#b"), cmd("sleep 12")]),
        ("echo foo # sleep 60", [cmd("echo foo")]),
        ("echo '#' \"#\" \\#", [cmd("echo # # #")]),
        ("echo $# ${#x}; a#b", [cmd("echo $# ${#x}"), cmd("a#b")]),
    ],
    "substitutions": [
        ("echo $(sleep 60)", [cmd(("echo", "$(sleep 60)")), cmd("sleep 60", "np")]),
        ("echo `sleep 60`", [cmd(("echo", "`sleep 60`")), cmd("sleep 60", "np")]),
        ("x=$(gh pr checks 1)", [cmd("gh pr checks 1", "np")]),
        (
            'echo "$(cat big; sleep 60)"',
            [
                cmd(("echo", "$(cat big; sleep 60)")),
                cmd("cat big", "np"),
                cmd("sleep 60", "np"),
            ],
        ),
        (
            "echo $(echo $(sleep 60))",
            [
                cmd(("echo", "$(echo $(sleep 60))")),
                cmd(("echo", "$(sleep 60)"), "np"),
                cmd("sleep 60", "np"),
            ],
        ),
        (
            "cat $(ls *.txt | head -1)",
            [
                cmd(("cat", "$(ls *.txt | head -1)")),
                cmd("ls *.txt", "np"),
                cmd("head -1", "np"),
            ],
        ),
        ("echo '$(sleep 60)'", [cmd(("echo", "$(sleep 60)"))]),
        ('echo "\\$(sleep 60)"', [cmd(("echo", "$(sleep 60)"))]),
        ("echo $((1 + 2)) && sleep 60", [cmd(("echo", "$((1 + 2))")), cmd("sleep 60")]),
        (
            "echo ${x:-$(sleep 60)}",
            [cmd(("echo", "${x:-$(sleep 60)}")), cmd("sleep 60", "np")],
        ),
        (
            '[ "$(printenv X)" = y ]',
            [cmd(("[", "$(printenv X)", "=", "y", "]")), cmd("printenv X", "np")],
        ),
        (
            "echo \"$(env | rg KEY)\" 'x'",
            [
                cmd(("echo", "$(env | rg KEY)", "x")),
                cmd("env", "np"),
                cmd("rg KEY", "np"),
            ],
        ),
    ],
    "process substitutions": [
        (
            "diff <(sort a) <(sort b)",
            [
                cmd(("diff", "<(sort a)", "<(sort b)")),
                cmd("sort a", "np"),
                cmd("sort b", "np"),
            ],
        ),
        ("cat big > >(wc -c)", [cmd("cat big", "f"), cmd("wc -c", "np")]),
        (
            "tee >(gzip > a.gz) < in",
            [cmd(("tee", ">(gzip > a.gz)")), cmd("gzip", "nf")],
        ),
        (
            "while read -r l; do echo $l; done < <(ls)",
            [cmd("read -r l", "w"), cmd("echo $l", "w"), cmd("ls", "np")],
        ),
    ],
    "env prefixes": [
        ('A=1 B="x y" sleep 60', [cmd("sleep 60")]),
        ("A=$(sleep 60) true", [cmd("sleep 60", "np"), cmd("true")]),
        ("FOO=bar", []),
        ("env A=1 sleep 60", [cmd("env A=1 sleep 60")]),
        (
            "export A=$(sleep 60) B=2",
            [cmd(("export", "A=$(sleep 60)", "B=2")), cmd("sleep 60", "np")],
        ),
        ("A=1 >f cat", [cmd("cat", "f")]),
    ],
    "chains": [
        ("cd sub && cat big", [cmd("cd sub"), cmd("cat big")]),
        ("a && b || c; d", [cmd("a"), cmd("b"), cmd("c"), cmd("d")]),
        ("a | b |& c", [cmd("a", "p"), cmd("b", "p"), cmd("c")]),
        ('echo "a && b; c | d"', [cmd(("echo", "a && b; c | d"))]),
        (
            "grep -E 'a|b' f | wc -l",
            [cmd(("grep", "-E", "a|b", "f"), "p"), cmd("wc -l")],
        ),
        ("cat big &", [cmd("cat big", "b")]),
        ("a & b", [cmd("a", "b"), cmd("b")]),
        ("a | b &", [cmd("a", "pb"), cmd("b", "b")]),
        ("a && b &", [cmd("a", "b"), cmd("b", "b")]),
        ("(a; b) | c", [cmd("a", "p"), cmd("b", "p"), cmd("c")]),
        ("! sleep 60", [cmd("sleep 60")]),
        ("time sleep 60", [cmd("sleep 60")]),
        ("{ a; b; } && c", [cmd("a"), cmd("b"), cmd("c")]),
        ("coproc sleep 60", [cmd("sleep 60")]),
    ],
    "redirects": [
        ("cat f 2>&1 | head", [cmd("cat f", "p"), cmd("head")]),
        ("cat f >/dev/null 2>&1", [cmd("cat f", "f")]),
        ("cat f 2>/dev/null", [cmd("cat f")]),
        ("cat f >&2", [cmd("cat f")]),
        ("cat f &>/dev/null", [cmd("cat f", "f")]),
        ("cat f >> log", [cmd("cat f", "f")]),
        ("cat f 3>x", [cmd("cat f")]),
        ("2>/dev/null cat f", [cmd("cat f")]),
        (">out cat f", [cmd("cat f", "f")]),
        ("echo x>y", [cmd("echo x", "f")]),
        ("echo 2>y", [cmd("echo")]),
        ("echo 2 >y", [cmd("echo 2", "f")]),
        ("nix build .#a >log 2>&1 &", [cmd("nix build .#a", "fb")]),
        ("{ cat big; } > f", [cmd("cat big", "f")]),
        ("(cat big) 2>/dev/null | wc", [cmd("cat big", "p"), cmd("wc")]),
        ("cat <f >g", [cmd("cat", "f")]),
        ("cat f >|g", [cmd("cat f", "f")]),
    ],
    "compounds": [
        (
            "until gh pr checks 1; do sleep 5; done",
            [cmd("gh pr checks 1", "w"), cmd("sleep 5", "w")],
        ),
        ("while true; do sleep 1; done", [cmd("true", "w"), cmd("sleep 1", "w")]),
        ("for i in 1 2; do sleep 1; done", [cmd("sleep 1", "o")]),
        ("for ((i=0;i<3;i++)); do sleep 1; done", [cmd("sleep 1", "o")]),
        (
            "if sleep 60; then echo a; else echo b; fi",
            [cmd("sleep 60"), cmd("echo a"), cmd("echo b")],
        ),
        (
            "if a; then b; elif c; then d; else e; fi",
            [cmd("a"), cmd("b"), cmd("c"), cmd("d"), cmd("e")],
        ),
        (
            "until true; do :; done; sleep 5",
            [cmd("true", "w"), cmd(":", "w"), cmd("sleep 5")],
        ),
        (
            "while a; do until b; do c; done; d; done; e",
            [cmd("a", "w"), cmd("b", "w"), cmd("c", "w"), cmd("d", "w"), cmd("e")],
        ),
        ("while a; do b; done > log", [cmd("a", "wf"), cmd("b", "wf")]),
        (
            'for f in $(seq 3); do cat "$f"; done',
            [cmd(("cat", "$f"), "o"), cmd("seq 3", "np")],
        ),
        ("case $x in a) sleep 60;; b|c) echo;; esac", [cmd("sleep 60"), cmd("echo")]),
        (
            "case x in $(sleep 60)) echo;; esac",
            [cmd("sleep 60", "np"), cmd("echo")],
        ),
        ("f() { sleep 60; }; f", [cmd("sleep 60"), cmd("f")]),
        ("[[ -f x ]] && sleep 60", [cmd("sleep 60")]),
        ("[[ $(sleep 60) == x ]]", [cmd("sleep 60", "np")]),
        ("(( i > 0 )) && echo y", [cmd("echo y")]),
        ("echo for while until done do", [cmd("echo for while until done do")]),
        ("echo done; sleep 5", [cmd("echo done"), cmd("sleep 5")]),
        ("select x in a b; do sleep 1; done", [cmd("sleep 1", "o")]),
        ("while a\ndo\n  b\ndone", [cmd("a", "w"), cmd("b", "w")]),
    ],
    "line continuations": [
        ("sleep \\\n  60", [cmd("sleep 60")]),
        ("gh pr \\\n  checks 1 \\\n  --watch", [cmd("gh pr checks 1 --watch")]),
        ('echo "a\\\nb"', [cmd("echo ab")]),
        ("cat big \\\n  | wc", [cmd("cat big", "p"), cmd("wc")]),
        ("a &&\\\n b", [cmd("a"), cmd("b")]),
        ("a |\n b", [cmd("a", "p"), cmd("b")]),
        ("a &&\n  b", [cmd("a"), cmd("b")]),
        ("sle\\\nep 60", [cmd("sleep 60")]),
    ],
    "quoting": [
        ('ec"ho" hi', [cmd("echo hi")]),
        ("e\\cho hi", [cmd("echo hi")]),
        ("echo a\\ b", [cmd(("echo", "a b"))]),
        ("cat 'a b'\"c d\"e", [cmd(("cat", "a bc de"))]),
        ("cat *.md {a,b}", [cmd("cat *.md {a,b}")]),
        (
            "echo 'é' $(sleep 60) \"$x\"",
            [cmd(("echo", "é", "$(sleep 60)", "$x")), cmd("sleep 60", "np")],
        ),
        ('cat "$HOME/a b"', [cmd(("cat", "$HOME/a b"))]),
        ('echo "a \\"b\\" \\\\c \\d"', [cmd(("echo", 'a "b" \\c \\d'))]),
    ],
}
# What bash and shfmt both reject.
INVALID: list[str] = [
    "if (",
    'echo "unterminated',
    "echo $(sleep 60",
    "until true; do",
    "a &&",
    "| a",
    "for",
    "fi",
    "echo )",
    "case x in",
    "a ;; b",
    "echo 'x",
    "(",
    "do sleep 60",
    "done",
    "cat <",
    "a | | b",
    "A=1 until true; do :; done",
    "echo ${",
    "echo $((1+",
]

# bash accepts these and shfmt, so `parse`, does not: command, then why it is fine.
STRICTER: list[tuple[str, str]] = [
    (
        "cat <<EOF\nabc",
        "An unclosed heredoc: bash warns and runs it, the guards allow this one command.",
    ),
]
