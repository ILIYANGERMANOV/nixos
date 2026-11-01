"""Properties of the parser every guard reads a command through.

Words are quoted with `shlex`, the stdlib oracle for shell quoting, so a property
compares what went in with what came out. `python-tests` substitutes the real
shfmt into `bash_commands`, as a guard's build does.
"""

import re
import shlex
import stat
from collections.abc import Callable
from pathlib import Path

import bash_commands
import pytest
from bash_commands import Loop, Parsed, Simple, Sink, Unparsable, parse
from guard_harness import Case, guard_cases
from hypothesis import example, given, settings
from hypothesis import strategies as st

# A generated run spawns shfmt per example, which a loaded machine can slow past
# hypothesis's default deadline.
runs_shfmt = settings(deadline=None)

# Any word, so what a shell quotes, but for what shfmt cannot read back: NUL, which
# no shell holds either, CR, which it drops before a newline even in quotes, and its
# two internal markers. U+0080 reads as the end of input, so Unparsable, and U+0081
# as a line continuation, so a wrong word. No real command holds either.
UNREADABLE = "\0\r\x80\x81"
any_words = st.text(
    st.characters(exclude_characters=UNREADABLE, exclude_categories=("Cs",))
)
plain_words = st.from_regex(r"[a-z0-9_./-]+", fullmatch=True)
# `run` first: a quoted word is only safe from keywords and assignments there.
any_argvs = st.lists(any_words).map(lambda words: ["run", *words])
plain_argvs = st.lists(plain_words).map(lambda words: ["run", *words])
body_lines = st.text(
    st.characters(exclude_characters=UNREADABLE + "\n", exclude_categories=("Cs",))
)
# What an unquoted heredoc does not expand.
inert_lines = st.text(
    st.characters(exclude_characters=UNREADABLE + "\n$`\\", exclude_categories=("Cs",))
)
shell_soup = st.text("$()`'\"\\|&;<>{}#\n ab")


def double_quoted(word: str) -> str:
    return '"' + re.sub(r'([$`"\\])', r"\\\1", word) + '"'


def backslashed(word: str) -> str:
    """A backslash before a newline continues the line, so that one is quoted."""
    return "".join("'\n'" if char == "\n" else "\\" + char for char in word) or "''"


def argv(command: str) -> tuple[str, ...]:
    return tuple(command.split())


def parsed(command: str) -> tuple[Simple, ...]:
    script = parse(command)
    assert isinstance(script, Parsed), script
    return script.commands


def joined(argvs: list[list[str]]) -> str:
    return " ; ".join(map(shlex.join, argvs))


def fake_shfmt(directory: Path, script: str) -> str:
    """An executable to stand in for shfmt, for what the real one will not do."""
    fake = directory / "shfmt"
    _ = fake.write_text(f"#!/bin/sh\n{script}\n")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    return str(fake)


PARSE_CASES: list[Case[str, tuple[Simple, ...]]] = [
    ((), "nothing is no command", ""),
    ((), "a comment is no command", "# sleep 60"),
    ((), "a bare assignment is no command", "A=1"),
    ((Simple(argv("sleep 60")),), "a simple command", "sleep 60"),
    ((Simple(argv("sleep 60")),), "an env prefix is no word", "A=1 B=2 sleep 60"),
    (
        (Simple(argv("a b")), Simple(argv("c"))),
        "a newline separates commands",
        "a b\nc",
    ),
    (
        (Simple(argv("a")), Simple(argv("b")), Simple(argv("c"))),
        "and-or lists and negation are transparent",
        "! a && b || c",
    ),
    (
        (Simple(("export", "A=1$(b)")), Simple(argv("b"), Sink.PIPE, substituted=True)),
        "a declaration is a command, and its value can run one",
        "export A=1$(b)",
    ),
    (
        (Simple(("declare", "-x", 'A="b c"')),),
        "a declaration keeps its arguments as source text",
        'declare -x A="b c"',
    ),
    (
        (Simple(argv("sleep 60")),),
        "time wraps a command",
        "time sleep 60",
    ),
    (
        (Simple(argv("sleep 60")),),
        "coproc wraps a command",
        "coproc sleep 60",
    ),
    ((), "time alone runs nothing", "time"),
    (
        (Simple(argv("a")), Simple(argv("b")), Simple(argv("c")), Simple(argv("d"))),
        "if, elif and else all run",
        "if a; then b; elif c; then d; fi",
    ),
    (
        (Simple(argv("b")), Simple(argv("c"))),
        "every case arm runs",
        "case x in a) b;; *) c;; esac",
    ),
    (
        (
            Simple(argv("a"), Sink.PIPE, substituted=True),
            Simple(argv("b"), Sink.PIPE, substituted=True),
            Simple(argv("c")),
        ),
        "a case subject and pattern can run a command",
        "case $(a) in $(b)) c;; esac",
    ),
    ((Simple(argv("a")),), "a function body counts", "f() { a; }"),
    (
        (Simple(argv("a"), Sink.PIPE, substituted=True),),
        "a test can run a command",
        '[[ -n "$(a)" ]]',
    ),
    (
        (Simple(argv("a"), Sink.PIPE, substituted=True),),
        "arithmetic can run a command",
        "(( $(a) > 0 ))",
    ),
    # Redirections
    (
        (Simple(argv("a"), Sink.FILE),),
        "stdout to a file",
        "a > f",
    ),
    ((Simple(argv("a"), Sink.FILE),), "a redirect can come first", "> f a"),
    ((Simple(argv("a"), Sink.FILE),), "stdout and stderr to a file", "a &> f"),
    ((Simple(argv("a"), Sink.FILE),), "appending both to a file", "a &>> f"),
    ((Simple(argv("a"), Sink.FILE),), "the csh spelling of &>", "a >& f"),
    ((Simple(argv("a"), Sink.FILE),), "clobbering a file", "a >| f"),
    ((Simple(argv("a"), Sink.FILE),), "stdout opened read-write", "a 1<> f"),
    ((Simple(argv("a")),), "stdin opened read-write", "a <> f"),
    ((Simple(argv("a")),), "a stdout duplicate is no file", "a >&2"),
    ((Simple(argv("a")),), "a stderr duplicate is no file", "a 2>&1"),
    ((Simple(argv("a")),), "a named descriptor is not stdout", "a {fd}> f"),
    ((Simple(argv("a")),), "a read is no redirect of stdout", "a < f"),
    ((Simple(argv("a")),), "a here-string is no redirect of stdout", "a <<< b"),
    (
        (Simple(argv("a")), Simple(argv("EOF"))),
        "a here-string has no body",
        "a <<< EOF\nEOF",
    ),
    ((Simple(argv("a 2")),), "a spaced digit is a word, not a fd", "a 2 2> f"),
    (
        (Simple(argv("a"), Sink.FILE),),
        "the order of duplicate and file does not matter",
        "a 2>&1 > f",
    ),
    (
        (Simple(argv("a"), Sink.PIPE), Simple(argv("b"), Sink.FILE)),
        "a block's redirect reaches only what writes to it",
        "{ a | b; } > f",
    ),
    (
        (Simple(argv("a"), Sink.FILE), Simple(argv("b"), Sink.PIPE), Simple(argv("c"))),
        "an inner redirect beats the block's pipe",
        "{ a > f; b; } | c",
    ),
    (
        (Simple(argv("a"), Sink.FILE), Simple(argv("b"))),
        "a redirect beats the pipe it would have reached",
        "a > f | b",
    ),
    (
        (Simple(argv("a"), Sink.PIPE), Simple(argv("b"), Sink.PIPE), Simple(argv("c"))),
        "a block in a pipeline pipes all it holds",
        "{ a; b; } | c",
    ),
    (
        (Simple(argv("a"), Sink.FILE), Simple(argv("b"), Sink.FILE)),
        "an if passes its redirect down",
        "if a; then b; fi > f",
    ),
    (
        (
            Simple(argv("a"), Sink.FILE, looped=Loop.ON_CONDITION),
            Simple(argv("b"), Sink.FILE, looped=Loop.ON_CONDITION),
        ),
        "a loop passes its redirect down",
        "while a; do b; done > f",
    ),
    (
        (Simple(argv("a"), Sink.PIPE), Simple(argv("b"))),
        "|& is a pipe",
        "a |& b",
    ),
    # Background
    (
        (Simple(argv("a"), background=True), Simple(argv("b"))),
        "only what precedes the & is in the background",
        "a & b",
    ),
    (
        (
            Simple(argv("a"), Sink.PIPE, background=True),
            Simple(argv("b"), background=True),
        ),
        "a whole pipeline goes to the background",
        "a | b &",
    ),
    (
        (Simple(argv("a"), background=True), Simple(argv("b"), background=True)),
        "a whole and-list goes to the background",
        "a && b &",
    ),
    (
        (Simple(argv("a"), background=True), Simple(argv("b"), background=True)),
        "a whole subshell goes to the background",
        "(a; b) &",
    ),
    (
        (
            Simple(("a", "$(b)"), background=True),
            Simple(argv("b"), Sink.PIPE, background=True, substituted=True),
        ),
        "a substitution waits in the background with its command",
        "a $(b) &",
    ),
    (
        (Simple(argv("tee f"), background=True), Simple(argv("sleep 12"))),
        "a heredoc leaves the & on its command",
        "tee f <<EOF &\nx\nEOF\nsleep 12",
    ),
    # Substitutions
    (
        (Simple(("echo", "$(a)")), Simple(argv("a"), Sink.PIPE, substituted=True)),
        "a command substitution stays source text and runs",
        "echo $(a)",
    ),
    (
        (Simple(("echo", "`a`")), Simple(argv("a"), Sink.PIPE, substituted=True)),
        "a backtick runs a command",
        "echo `a`",
    ),
    (
        (Simple(("cat", "<(a)")), Simple(argv("a"), Sink.PIPE, substituted=True)),
        "a process substitution runs a command",
        "cat <(a)",
    ),
    (
        (
            Simple(("echo", "$(a; b)")),
            Simple(argv("a"), Sink.PIPE, substituted=True),
            Simple(argv("b"), Sink.PIPE, substituted=True),
        ),
        "a double-quoted substitution runs",
        'echo "$(a; b)"',
    ),
    (
        (
            Simple(("echo", "${x:-$(a)}")),
            Simple(argv("a"), Sink.PIPE, substituted=True),
        ),
        "a parameter default can run a command",
        "echo ${x:-$(a)}",
    ),
    (
        (Simple(argv("a"), Sink.PIPE, substituted=True),),
        "a bare assignment can run a command",
        "A=$(a)",
    ),
    (
        (Simple(argv("b")), Simple(argv("a"), Sink.PIPE, substituted=True)),
        "an env prefix can run a command",
        "A=$(a) b",
    ),
    (
        (
            Simple(("echo", "$(a $(b))")),
            Simple(("a", "$(b)"), Sink.PIPE, substituted=True),
            Simple(argv("b"), Sink.PIPE, substituted=True),
        ),
        "substitutions nest",
        "echo $(a $(b))",
    ),
    (
        (
            Simple(("echo", "`a \\`b | c\\``")),
            Simple(("a", "`b | c\\`"), Sink.PIPE, substituted=True),
            Simple(argv("b"), Sink.PIPE, substituted=True),
            Simple(argv("c"), Sink.PIPE, substituted=True),
        ),
        "an escaped backtick nests, and its operators read true",
        "echo `a \\`b | c\\``",
    ),
    (
        (Simple(("echo", "$(a > f)")), Simple(argv("a"), Sink.FILE, substituted=True)),
        "a redirect inside a substitution beats its pipe",
        "echo $(a > f)",
    ),
    (
        (Simple(argv("a"), Sink.FILE), Simple(argv("b"), Sink.PIPE, substituted=True)),
        "a redirect target can run a command",
        "a > $(b)",
    ),
    (
        (Simple(("echo", "$()")),),
        "an empty substitution runs nothing",
        "echo $()",
    ),
    # Heredocs
    (
        (Simple(argv("cat"), Sink.PIPE), Simple(argv("tee f"))),
        "a heredoc body is no command",
        "cat <<'EOF' | tee f\nsleep 60 && rm -rf /\nEOF",
    ),
    (
        (Simple(argv("cat")), Simple(argv("sleep 60"), Sink.PIPE, substituted=True)),
        "an unquoted heredoc body substitutes",
        "cat <<EOF\n$(sleep 60)\nEOF",
    ),
    ((Simple(argv("cat")),), "'EOF' keeps $() literal", "cat <<'EOF'\n$(a)\nEOF"),
    ((Simple(argv("cat")),), '"EOF" keeps $() literal', 'cat <<"EOF"\n$(a)\nEOF'),
    ((Simple(argv("cat")),), "\\EOF keeps $() literal", "cat <<\\EOF\n$(a)\nEOF"),
    (
        (Simple(argv("cat")), Simple(argv("wc -l"))),
        "two heredocs on one line",
        "cat <<A <<'B'\n1\nA\n2\nB\nwc -l",
    ),
    (
        (Simple(argv("cat")), Simple(argv("echo done"))),
        "<<- strips tabs from the delimiter",
        "cat <<-EOF\n\tx\n\tEOF\necho done",
    ),
    (
        (Simple(argv("python3 -")),),
        "a dash before a heredoc is a word",
        "python3 - <<'PY'\nimport time\nPY",
    ),
    (
        (Simple(argv("cat"), Sink.FILE),),
        "a heredoc does not hide a file sink",
        "cat <<EOF > out\nhello\nEOF",
    ),
    # Loops
    (
        (
            Simple(argv("a"), looped=Loop.ON_CONDITION),
            Simple(argv("b"), looped=Loop.ON_CONDITION),
        ),
        "while repeats its condition and its body",
        "while a; do b; done",
    ),
    (
        (
            Simple(argv("a"), looped=Loop.ON_CONDITION),
            Simple(argv("b"), looped=Loop.ON_CONDITION),
        ),
        "until repeats its condition and its body",
        "until a; do b; done",
    ),
    (
        (Simple(argv("a"), looped=Loop.OVER_LIST),),
        "for repeats over a list",
        "for i in 1 2; do a; done",
    ),
    (
        (Simple(argv("a"), looped=Loop.OVER_LIST),),
        "a C-style for repeats over a list",
        "for ((i = 0; i < 2; i++)); do a; done",
    ),
    (
        (Simple(argv("a"), looped=Loop.OVER_LIST),),
        "select repeats over a list",
        "select i in 1 2; do a; done",
    ),
    (
        (Simple(argv("a"), looped=Loop.ON_CONDITION),),
        "a condition loop outside a list loop wins",
        "while [[ x ]]; do for i in 1; do a; done; done",
    ),
    (
        (Simple(argv("a"), looped=Loop.ON_CONDITION),),
        "a condition loop inside a list loop wins",
        "for i in 1; do while [[ x ]]; do a; done; done",
    ),
    (
        (
            Simple(argv("a"), Sink.PIPE, substituted=True),
            Simple(argv("b"), looped=Loop.OVER_LIST),
        ),
        "a for list runs once, before the loop",
        "for i in $(a); do b; done",
    ),
    (
        (
            Simple(argv("a"), Sink.PIPE, looped=Loop.ON_CONDITION, substituted=True),
            Simple(argv("b"), looped=Loop.ON_CONDITION),
        ),
        "a substitution in a loop repeats",
        "until [[ $(a) ]]; do b; done",
    ),
    # Comments and quoting
    (
        (Simple(argv("nix build .#ci")), Simple(argv("sleep 12"))),
        "a hash inside a word is no comment",
        "nix build .#ci # a comment\nsleep 12",
    ),
    (
        (Simple(argv("a#b")), Simple(argv("sleep 12"))),
        "a comment ends at its newline",
        "a#b # sleep 60; c\nsleep 12",
    ),
    (
        (Simple(argv("sleep 60")),),
        "a line continuation joins two lines",
        "sleep \\\n60",
    ),
    (
        (Simple(argv("sleep 60")),),
        "a line continuation joins a word",
        "sle\\\nep 60",
    ),
    (
        (Simple(argv("sleep 60")),),
        "a quoted command word is the same command",
        "'sl'\"ee\"\\p 60",
    ),
    (
        (Simple(("echo", "a b", "c$d", "$e f")),),
        "double quotes keep an expansion's source text",
        "echo 'a b' 'c$d' \"$e f\"",
    ),
    (
        (Simple(("cp", "caf\u00e9 \u00e0", "${x}")),),
        "offsets count bytes, so text after unicode reads true",
        "cp 'caf\u00e9 \u00e0' ${x}",
    ),
]


@guard_cases(PARSE_CASES)
def test_parse(want: tuple[Simple, ...], given: str) -> None:
    assert parsed(given) == want


@pytest.mark.parametrize(
    "command",
    ["if", "fi", "done", "cat <(", "(", 'echo "a', "echo 'a", "a |", "a && ", "$("],
)
def test_invalid_bash_is_unparsable_and_says_why(command: str) -> None:
    script = parse(command)

    assert isinstance(script, Unparsable)
    assert re.match(r"\d+:\d+: ", script.reason)


def test_an_unencodable_command_is_unparsable() -> None:
    assert isinstance(parse("echo \ud800"), Unparsable)


def test_a_chain_too_deep_to_walk_is_unparsable() -> None:
    assert isinstance(parse(" | ".join(["a"] * 2000)), Unparsable)


def test_a_missing_shfmt_is_unparsable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(bash_commands, "SHFMT", str(tmp_path / "missing"))

    assert isinstance(parse("sleep 60"), Unparsable)


def test_a_hanging_shfmt_times_out_as_unparsable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(bash_commands, "SHFMT", fake_shfmt(tmp_path, "exec sleep 30"))

    script = parse("sleep 60")

    assert isinstance(script, Unparsable)
    assert "Timeout" in script.reason


@pytest.mark.parametrize(
    "output",
    [
        "not json",
        "[]",
        '{"Stmts": 1}',
        '{"Stmts": [{"Cmd": {"Kind": "CallExpr"}}]}',
        '{"Stmts": [{"Cmd": {"Type": "CallExpr", "Args": [{"Parts": [{}]}]}}]}',
        '{"Stmts": [{"Redirs": [{"OpPos": {"Offset": 0}}]}]}',
    ],
    ids=[
        "not JSON",
        "the wrong top level",
        "the wrong type of field",
        "a renamed field",
        "a part without a type",
        "an operator not in the source",
    ],
)
def test_json_of_another_shape_is_unparsable(
    output: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake = fake_shfmt(tmp_path, f"echo {shlex.quote(output)}")
    monkeypatch.setattr(bash_commands, "SHFMT", fake)

    assert isinstance(parse("sleep 60"), Unparsable)


@runs_shfmt
@given(st.one_of(st.text(), shell_soup))
@example("\0")
def test_parse_is_total(command: str) -> None:
    assert isinstance(parse(command), Parsed | Unparsable)


@runs_shfmt
@given(
    st.lists(any_argvs, min_size=1),
    st.sampled_from([shlex.quote, double_quoted, backslashed]),
)
def test_quote_removal_restores_every_word(
    argvs: list[list[str]], quote: Callable[[str], str]
) -> None:
    text = " ; ".join(" ".join(map(quote, words)) for words in argvs)

    assert [list(command.words) for command in parsed(text)] == argvs


@runs_shfmt
@given(st.lists(any_argvs, min_size=2))
def test_every_pipeline_stage_but_the_last_writes_to_a_pipe(
    argvs: list[list[str]],
) -> None:
    commands = parsed(" | ".join(map(shlex.join, argvs)))

    assert [command.sink for command in commands] == [Sink.PIPE] * (len(argvs) - 1) + [
        Sink.SCREEN
    ]
    assert [list(command.words) for command in commands] == argvs


@runs_shfmt
@given(
    any_argvs,
    any_words,
    st.sampled_from([">", ">>", "1>", "1>>", ">|", "&>", "&>>"]),
)
def test_a_stdout_redirect_is_a_file_sink_and_no_word(
    words: list[str], target: str, operator: str
) -> None:
    [redirected] = parsed(f"{shlex.join(words)} {operator} {shlex.quote(target)}")

    assert redirected == Simple(tuple(words), Sink.FILE)


@runs_shfmt
@given(any_argvs, any_words, st.sampled_from(["2>", "2>>", "2>&", "<", "3>"]))
def test_another_descriptor_leaves_stdout_alone(
    words: list[str], target: str, operator: str
) -> None:
    [redirected] = parsed(f"{shlex.join(words)} {operator} {shlex.quote(target)}")

    assert redirected == Simple(tuple(words))


@runs_shfmt
@given(any_argvs, st.integers(min_value=0))
def test_stdout_duplicated_onto_a_descriptor_is_no_file(
    words: list[str], descriptor: int
) -> None:
    [redirected] = parsed(f"{shlex.join(words)} >&{descriptor}")

    assert redirected == Simple(tuple(words))


@runs_shfmt
@given(any_argvs)
def test_a_trailing_ampersand_sends_the_command_to_the_background(
    words: list[str],
) -> None:
    [backgrounded] = parsed(f"{shlex.join(words)} &")

    assert backgrounded == Simple(tuple(words), background=True)


@runs_shfmt
@given(
    st.lists(any_argvs, min_size=1),
    st.sampled_from(
        ["{{ {}; }}", "( {} )", "if [[ x ]]; then {}; fi", "for i in 1; do {}; done"]
    ),
)
def test_a_compound_passes_its_redirect_to_all_it_holds(
    argvs: list[list[str]], compound: str
) -> None:
    commands = parsed(compound.format(joined(argvs)) + " > f")

    assert [list(command.words) for command in commands] == argvs
    assert {command.sink for command in commands} == {Sink.FILE}


@runs_shfmt
@given(
    st.lists(plain_argvs, min_size=1),
    st.sampled_from(["$({})", "`{}`", "<({})", '"$({})"']),
)
def test_a_substitution_marks_all_it_holds_as_piped_and_substituted(
    argvs: list[list[str]], substitution: str
) -> None:
    [_, *inner] = parsed("outer " + substitution.format(joined(argvs)))

    assert inner == [
        Simple(tuple(words), Sink.PIPE, substituted=True) for words in argvs
    ]


@runs_shfmt
@given(plain_argvs, st.integers(min_value=0))
def test_a_line_continuation_changes_nothing(words: list[str], at: int) -> None:
    text = shlex.join(words)
    cut = at % (len(text) + 1)

    assert parse(f"{text[:cut]}\\\n{text[cut:]}") == parse(text)


@runs_shfmt
@given(plain_words, plain_words, body_lines)
def test_a_hash_only_starts_a_comment_at_a_word(
    head: str, tail: str, comment: str
) -> None:
    commands = parsed(f"run {head}#{tail} # {comment}\nnext")

    assert commands == (Simple(("run", f"{head}#{tail}")), Simple(("next",)))


@runs_shfmt
@given(
    st.lists(body_lines),
    st.sampled_from(["<<'{}'", '<<"{}"', "<<\\{}", "<<-'{}'"]),
)
def test_a_quoted_heredoc_body_never_runs(body: list[str], heredoc: str) -> None:
    delimiter = "END"
    clean_body = [line for line in body if line.strip() != delimiter]
    text = "\n".join(["cat " + heredoc.format(delimiter), *clean_body, delimiter, "b"])

    assert parsed(text) == (Simple(("cat",)), Simple(("b",)))


@runs_shfmt
@given(
    st.lists(inert_lines),
    st.sampled_from(["<<{}", "<<-{}", "<< {}"]),
)
def test_an_unquoted_heredoc_body_without_expansions_never_runs(
    body: list[str], heredoc: str
) -> None:
    delimiter = "END"
    clean_body = [line for line in body if line.strip() != delimiter]
    text = "\n".join(["cat " + heredoc.format(delimiter), *clean_body, delimiter, "b"])

    assert parsed(text) == (Simple(("cat",)), Simple(("b",)))
