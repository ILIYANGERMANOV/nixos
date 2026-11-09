"""The log: a written log replays to the fold of its events, and a hand-edited
bad line stops every command, naming it."""

from pathlib import Path

import pytest
from hypothesis import given

from state.codec import Line, encode_line, parse_log, replay
from state.core import fold
from state.model import Event, Failure
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
