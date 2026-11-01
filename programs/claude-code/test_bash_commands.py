"""Properties of the parser every guard reads a command through.

Words are quoted with `shlex`, the stdlib oracle for shell quoting, so a property
compares what went in with what came out. `python-tests` substitutes the real
shfmt into `bash_commands`, as a guard's build does.
"""

import os
import re
import shlex
import subprocess
from collections import Counter
from collections.abc import Callable
from pathlib import Path

import bash_commands
import pytest
from bash_commands import Parsed, Simple, Sink, Unparsable, parse
from bash_corpus import INVALID, PARSED, STRICTER, cmd
from guard_harness import Case, fake_shfmt, guard_cases
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


def text_without(excluded: str) -> st.SearchStrategy[str]:
    return st.text(
        st.characters(exclude_characters=excluded, exclude_categories=("Cs",))
    )


any_words = text_without(UNREADABLE)
plain_words = st.from_regex(r"[a-z0-9_./-]+", fullmatch=True)
# `run` first: a quoted word is only safe from keywords and assignments there.
any_argvs = st.lists(any_words).map(lambda words: ["run", *words])
plain_argvs = st.lists(plain_words).map(lambda words: ["run", *words])
body_lines = text_without(UNREADABLE + "\n")
# What an unquoted heredoc does not expand.
inert_lines = text_without(UNREADABLE + "\n$`\\")
shell_soup = st.text("$()`'\"\\|&;<>{}#\n ab")


def double_quoted(word: str) -> str:
    return '"' + re.sub(r'([$`"\\])', r"\\\1", word) + '"'


def backslashed(word: str) -> str:
    """A backslash before a newline continues the line, so that one is quoted."""
    return "".join("'\n'" if char == "\n" else "\\" + char for char in word) or "''"


def parsed(command: str) -> tuple[Simple, ...]:
    script = parse(command)
    assert isinstance(script, Parsed), script
    return script.commands


def joined(argvs: list[list[str]]) -> str:
    return " ; ".join(map(shlex.join, argvs))


def heredoc_then_next(opener: str, body: list[str]) -> str:
    """`cat`, reading `body` through `opener`, then the command `b`."""
    delimiter = "END"
    lines = [line for line in body if line.strip() != delimiter]
    return "\n".join(["cat " + opener.format(delimiter), *lines, delimiter, "b"])


def bash_accepts(command: str) -> bool:
    bash = subprocess.run(
        [os.environ["BASH_ORACLE"], "-n", "-c", command],
        capture_output=True,
        check=False,
    )
    return bash.returncode == 0


def shfmt_rejects(command: str) -> bool:
    """Only shfmt's own `line:col: reason`: a broken adapter is no rejection."""
    match parse(command):
        case Unparsable(reason):
            return re.match(r"\d+:\d+: ", reason) is not None
        case Parsed():
            return False


PARSE_CASES: list[Case[str, tuple[Simple, ...]]] = [
    ((), "nothing is no command", ""),
    ((), "a comment is no command", "# sleep 60"),
    ((cmd("a b"), cmd("c")), "a newline separates commands", "a b\nc"),
    (
        (cmd("a"), cmd("b"), cmd("c")),
        "and-or lists and negation are transparent",
        "! a && b || c",
    ),
    (
        (cmd(("export", "A=1$(b)")), cmd("b", "np")),
        "a declaration is a command, and its value can run one",
        "export A=1$(b)",
    ),
    (
        (cmd(("declare", "-x", 'A="b c"')),),
        "a declaration keeps its arguments as source text",
        'declare -x A="b c"',
    ),
    ((), "time alone runs nothing", "time"),
    (
        (cmd("a"), cmd("b"), cmd("c"), cmd("d")),
        "if, elif and else all run",
        "if a; then b; elif c; then d; fi",
    ),
    ((cmd("b"), cmd("c")), "every case arm runs", "case x in a) b;; *) c;; esac"),
    (
        (cmd("a", "np"), cmd("b", "np"), cmd("c")),
        "a case subject and pattern can run a command",
        "case $(a) in $(b)) c;; esac",
    ),
    ((cmd("a", "np"),), "arithmetic can run a command", "(( $(a) > 0 ))"),
    # Redirections
    ((cmd("a", "f"),), "appending both to a file", "a &>> f"),
    ((cmd("a", "f"),), "the csh spelling of &>", "a >& f"),
    ((cmd("a", "f"),), "stdout opened read-write", "a 1<> f"),
    ((cmd("a"),), "stdin opened read-write", "a <> f"),
    ((cmd("a"),), "a named descriptor is not stdout", "a {fd}> f"),
    ((cmd("a"), cmd("EOF")), "a here-string has no body", "a <<< EOF\nEOF"),
    ((cmd("a", "f"),), "the order of duplicate and file does not matter", "a 2>&1 > f"),
    (
        (cmd("a", "p"), cmd("b", "f")),
        "a block's redirect reaches only what writes to it",
        "{ a | b; } > f",
    ),
    (
        (cmd("a", "f"), cmd("b", "p"), cmd("c")),
        "an inner redirect beats the block's pipe",
        "{ a > f; b; } | c",
    ),
    (
        (cmd("a", "f"), cmd("b")),
        "a redirect beats the pipe it would have reached",
        "a > f | b",
    ),
    (
        (cmd("a", "f"), cmd("b", "f")),
        "an if passes its redirect down",
        "if a; then b; fi > f",
    ),
    # Background
    (
        (cmd("a", "b"), cmd("b", "b")),
        "a whole subshell goes to the background",
        "(a; b) &",
    ),
    (
        (cmd(("a", "$(b)"), "b"), cmd("b", "pbn")),
        "a substitution waits in the background with its command",
        "a $(b) &",
    ),
    # Substitutions
    (
        (cmd(("echo", "$(a $(b))")), cmd(("a", "$(b)"), "np"), cmd("b", "np")),
        "substitutions nest",
        "echo $(a $(b))",
    ),
    (
        (
            cmd(("echo", "`a \\`b | c\\``")),
            cmd(("a", "`b | c\\`"), "np"),
            cmd("b", "np"),
            cmd("c", "np"),
        ),
        "an escaped backtick nests, and its operators read true",
        "echo `a \\`b | c\\``",
    ),
    (
        (cmd("a", "f"), cmd("b", "np")),
        "a redirect target can run a command",
        "a > $(b)",
    ),
    ((cmd(("echo", "$()")),), "an empty substitution runs nothing", "echo $()"),
    # Heredocs
    ((cmd("cat"),), '"EOF" keeps $() literal', 'cat <<"EOF"\n$(a)\nEOF'),
    # Loops
    (
        (cmd("a", "w"), cmd("b", "w")),
        "while repeats its condition and its body",
        "while a; do b; done",
    ),
    (
        (cmd("a", "w"),),
        "a condition loop outside a list loop wins",
        "while [[ x ]]; do for i in 1; do a; done; done",
    ),
    (
        (cmd("a", "w"),),
        "a condition loop inside a list loop wins",
        "for i in 1; do while [[ x ]]; do a; done; done",
    ),
    (
        (cmd("a", "np"), cmd("b", "o")),
        "a for list runs once, before the loop",
        "for i in $(a); do b; done",
    ),
    (
        (cmd("a", "pwn"), cmd("b", "w")),
        "a substitution in a loop repeats",
        "until [[ $(a) ]]; do b; done",
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
    assert shfmt_rejects(command)


@guard_cases(
    [
        (Counter(want), f"{group}: {command}", command)
        for group, entries in PARSED.items()
        for command, want in entries
    ]
)
def test_corpus_what_bash_accepts_reads_as_its_commands(
    want: Counter[Simple], given: str
) -> None:
    assert bash_accepts(given)
    assert Counter(parsed(given)) == want


@pytest.mark.parametrize("command", INVALID)
def test_corpus_what_bash_rejects_shfmt_rejects(command: str) -> None:
    assert not bash_accepts(command)
    assert shfmt_rejects(command)


@pytest.mark.parametrize(
    "command", [command for command, _ in STRICTER], ids=[why for _, why in STRICTER]
)
def test_corpus_shfmt_is_stricter_than_bash_only_where_named(command: str) -> None:
    assert bash_accepts(command)
    assert shfmt_rejects(command)


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
    commands = parsed(heredoc_then_next(heredoc, body))

    assert commands == (cmd("cat"), cmd("b"))


@runs_shfmt
@given(
    st.lists(inert_lines),
    st.sampled_from(["<<{}", "<<-{}", "<< {}"]),
)
def test_an_unquoted_heredoc_body_without_expansions_never_runs(
    body: list[str], heredoc: str
) -> None:
    commands = parsed(heredoc_then_next(heredoc, body))

    assert commands == (cmd("cat"), cmd("b"))
