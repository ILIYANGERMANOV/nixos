"""Properties of the splitter every guard reads a command through.

Words are quoted with `shlex`, the stdlib oracle for shell quoting, so a property
compares what went in with what came out.
"""

import contextlib
import shlex

from bash_commands import (
    OPERATORS,
    Sink,
    redirects_stdout_to_file,
    simple_commands,
    strip_heredoc_bodies,
)
from hypothesis import given
from hypothesis import strategies as st

# A word the splitter keeps whole. It is not every word: an empty one or one of
# only operator characters reads as an operator, a mid-word `#` keeps its escape,
# and a newline splits even in quotes.
words = st.text(
    st.characters(exclude_characters="\n#", exclude_categories=("Cs",)), min_size=1
).filter(lambda word: not set(word) <= OPERATORS)
# `2 > f` reads the 2 as a file descriptor, a known gap: bash needs them touching.
last_words = words.filter(lambda word: not word.isdigit())
commands = st.tuples(st.lists(words), last_words).map(
    lambda parts: [*parts[0], parts[1]]
)
delimiters = st.from_regex(r"[A-Za-z_][A-Za-z0-9_]*", fullmatch=True)
lines = st.text(st.characters(exclude_characters="\n", exclude_categories=("Cs",)))
plain_lines = lines.filter(lambda line: "<<" not in line)
heredocs = st.sampled_from(["<<{}", "<<-{}", "<< {}", "<<'{}'", '<<"{}"'])


@given(st.lists(commands, min_size=1))
def test_words_survive_a_split_at_semicolons(given_commands: list[list[str]]) -> None:
    text = " ; ".join(map(shlex.join, given_commands))

    split = [command.words for command in simple_commands(text) if command.words]

    assert split == given_commands


@given(st.lists(commands, min_size=2))
def test_every_stage_of_a_pipeline_but_the_last_writes_to_a_pipe(
    given_commands: list[list[str]],
) -> None:
    text = " | ".join(map(shlex.join, given_commands))

    sinks = [command.sink for command in simple_commands(text)]

    assert sinks == [Sink.PIPE] * (len(given_commands) - 1) + [Sink.SCREEN]


@given(commands, words, st.sampled_from([">", ">>", "1>", "1>>"]))
def test_a_stdout_redirect_sinks_to_a_file_and_is_no_word(
    command: list[str], target: str, operator: str
) -> None:
    text = f"{shlex.join(command)} {operator} {shlex.quote(target)}"

    [redirected] = simple_commands(text)

    assert redirected.sink is Sink.FILE
    assert redirected.words == command


@given(commands, words)
def test_a_stderr_redirect_leaves_stdout_on_the_screen(
    command: list[str], target: str
) -> None:
    text = f"{shlex.join(command)} 2> {shlex.quote(target)}"

    [redirected] = simple_commands(text)

    assert redirected.sink is Sink.SCREEN
    assert redirected.words == command


@given(commands)
def test_a_trailing_ampersand_sends_the_command_to_the_background(
    command: list[str],
) -> None:
    [backgrounded, _] = simple_commands(f"{shlex.join(command)} &")

    assert backgrounded.background
    assert backgrounded.words == command


@given(lines)
def test_any_line_either_splits_or_fails_as_the_guards_expect(line: str) -> None:
    """A guard fails open on ValueError alone, so nothing else may escape."""
    with contextlib.suppress(ValueError):
        _ = list(simple_commands(line))


@given(st.lists(lines), st.lists(plain_lines), delimiters, heredocs)
def test_a_heredoc_loses_its_body_and_keeps_what_follows(
    body: list[str], after: list[str], delimiter: str, heredoc: str
) -> None:
    opener = "cat " + heredoc.format(delimiter)
    # The first delimiter line ends the body.
    clean_body = [line for line in body if line.strip() != delimiter]
    text = "\n".join([opener, *clean_body, delimiter, *after])

    assert strip_heredoc_bodies(text) == "\n".join([opener, *after])


@given(st.lists(plain_lines))
def test_a_command_without_a_heredoc_is_unchanged(given_lines: list[str]) -> None:
    text = "\n".join(given_lines)

    assert strip_heredoc_bodies(text) == text


@given(st.lists(plain_lines), delimiters)
def test_a_here_string_has_no_body_to_strip(after: list[str], delimiter: str) -> None:
    text = "\n".join([f"cat <<< {delimiter}", *after])

    assert strip_heredoc_bodies(text) == text


@given(
    st.text().filter(lambda fd: fd != "1"),
    st.sampled_from([">", ">>", ">&"]),
    st.text(),
)
def test_a_redirect_of_another_descriptor_never_moves_stdout(
    fd: str, operator: str, target: str
) -> None:
    assert not redirects_stdout_to_file(fd, operator, target)


@given(st.integers(min_value=0).map(str))
def test_stdout_duplicated_onto_a_descriptor_is_no_file_redirect(target: str) -> None:
    assert not redirects_stdout_to_file("1", ">&", target)
