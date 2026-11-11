"""The log: a written log replays to the fold of its events, and a hand-edited
bad line stops every command, naming it."""

from pathlib import Path

import pytest
from hypothesis import given

from state.codec import Line, encode_line, parse_log, replay
from state.core import fold
from state.model import Event, Failure, Implemented, Started
from state.state_fixtures import accepted, event_lists, ok, run

LOG = Path("/notes/run/events.jsonl")


@given(event_lists)
def test_replay_the_written_log_replays_to_the_fold_of_its_events(
    candidates: list[Event],
) -> None:
    run = accepted(candidates)
    text = "".join(
        encode_line(Line(n, "t", None, None, event))
        for n, event in enumerate(run, start=1)
    )

    match parse_log(text, LOG):
        case Failure() as failure:
            raise AssertionError(failure.message)
        case lines:
            assert replay(lines, LOG) == fold(run)


@pytest.mark.parametrize(
    ("bad", "why"),
    [
        pytest.param("{not json\n", "not JSON", id="not JSON"),
        pytest.param('{"seq":3}', "no newline at its end", id="no newline"),
        pytest.param(
            '{"seq":9,"ts":"t","head":null,"session":null,"event":{"type":"confirmed"}}\n',
            "seq is 9, expected 3", id="a seq gap",
        ),
        pytest.param(
            '{"seq":3,"ts":"t","head":null,"session":null,"event":{"type":"shipped"}}\n',
            "unknown event type 'shipped'", id="an unknown event",
        ),
        pytest.param(
            ('{"seq":3,"ts":"t","head":null,"session":null,'
            '"event":{"type":"asked","n":1,"extra":1}}\n'),
            "unknown ['extra']", id="an unknown field",
        ),
        pytest.param(
            '{"seq":3,"ts":"t","head":null,"session":null,"event":{"type":"asked","n":0}}\n',
            "n is not a positive integer", id="a bad value",
        ),
    ],
)  # fmt: skip
@pytest.mark.parametrize("command", [("next",), ("show",), ("record", "asked")])
def test_a_hand_edited_bad_line_makes_every_command_exit_2_naming_it(
    repo: Path, tmp_path: Path, bad: str, why: str, command: tuple[str, ...]
) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    _ = ok(repo, "record", "size", "Normal")
    log = notes / "events.jsonl"
    with log.open("a") as file:
        _ = file.write(bad)

    code, out, err = run(repo, *command)

    assert (code, out) == (2, "")
    message, fix = err.splitlines()
    assert message.startswith(f"state: {log}:3: ") and why in message
    assert fix == (
        f"fix: repair or delete line 3 of {log}: the log is append-only, so a bad "
        "line is a hand edit, or a log an older state wrote; the state hooks stay "
        "silent until it parses"
    )


STARTED_V1 = '{"type":"started","notes":"/notes/run","delegated":false}'


def a_log(*events: str) -> str:
    return "".join(
        f'{{"seq":{n},"ts":"t","head":null,"session":null,"event":{event}}}\n'
        for n, event in enumerate(events, start=1)
    )


def test_a_started_line_without_a_version_is_a_v1_log() -> None:
    match parse_log(a_log(STARTED_V1), LOG):
        case Failure() as failure:
            raise AssertionError(failure.message)
        case [line]:
            assert line.event == Started("/notes/run", delegated=False, version=1)
        case lines:
            raise AssertionError(lines)


def test_an_implemented_line_in_a_v1_log_without_touches_touches_no_area() -> None:
    old = a_log(STARTED_V1, '{"type":"implemented","head":"h1"}')

    match parse_log(old, LOG):
        case Failure() as failure:
            raise AssertionError(failure.message)
        case [_, line]:
            assert line.event == Implemented("h1", ())
            assert '"touches":[]' in encode_line(line)
        case lines:
            raise AssertionError(lines)


def test_an_implemented_line_in_a_v2_log_needs_its_touches() -> None:
    started = STARTED_V1.replace("}", ',"version":2}')
    log = a_log(started, '{"type":"implemented","head":"h1"}')

    match parse_log(log, LOG):
        case Failure() as failure:
            assert failure.message == (f"state: {LOG}:2: touches is not a list")
        case lines:
            raise AssertionError(lines)


@pytest.mark.parametrize("version", ["3", "0", "true", '"2"'])
def test_a_log_of_an_unknown_version_fails_naming_it(version: str) -> None:
    started = STARTED_V1.replace("}", f',"version":{version}}}')

    match parse_log(a_log(started), LOG):
        case Failure() as failure:
            assert failure.message == (
                f"state: {LOG}:1: version {version} is a log version this state has "
                "no rules for; it reads 1, 2: update state"
            )
        case lines:
            raise AssertionError(lines)
