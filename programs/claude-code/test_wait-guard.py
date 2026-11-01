"""The wait guard, on the Bash calls of the main agent and of its subagents."""

import json
import os
from pathlib import Path

import bash_commands
import pytest
from guard_harness import (
    ALLOWED,
    BLOCKED,
    BROKEN_SHFMT,
    FAIL_OPEN_CASES,
    BrokenShfmt,
    Case,
    agent_fields,
    bash_event,
    guard_cases,
    guard_on,
    guard_on_broken,
    run_guard,
    session_with,
)

GUARD = os.environ["WAIT_GUARD"]
SOURCE = "wait-guard.py"

FOREGROUND_CASES: list[Case[str]] = [
    (BLOCKED, "a long sleep is blocked", "sleep 30"),
    (BLOCKED, "a sleep with a unit is blocked", "sleep 1m"),
    (
        BLOCKED,
        "a long sleep after another command is blocked",
        "nix build && sleep 600; cat log",
    ),
    (
        BLOCKED,
        "an until loop around a sleep is blocked",
        "until [ -f x ]; do sleep 5; done",
    ),
    (
        BLOCKED,
        "a while loop around a sleep is blocked",
        "while pgrep foo; do sleep 2; done",
    ),
    (BLOCKED, "a multi-line poll is blocked", "while true\ndo\n  sleep 1\ndone"),
    (
        BLOCKED,
        "a sleep as a while condition is blocked",
        "while sleep 5; do curl x && break; done",
    ),
    (BLOCKED, "a sleep as an until condition is blocked", "until sleep 3; do :; done"),
    (BLOCKED, "a long sleep as an if condition is blocked", "if sleep 30; then ls; fi"),
    (ALLOWED, "invalid Bash is allowed, whatever it names", "sleep 30 && ("),
    (ALLOWED, "a short sleep is allowed", "sleep 2"),
    (ALLOWED, "a short sleep as an if condition is allowed", "if sleep 2; then ls; fi"),
    (
        ALLOWED,
        "a loop without a sleep is allowed",
        'while read l; do echo "$l"; done < f',
    ),
    (
        ALLOWED,
        "a sleep named in a string is allowed",
        "echo 'sleep 30' && git commit -m 'until done, sleep 60'",
    ),
    (
        ALLOWED,
        "a heredoc body naming a sleep is allowed",
        "cat > s.sh <<'EOF'\nsleep 30\nEOF",
    ),
    (
        BLOCKED,
        "a poll in bash -c is blocked",
        "bash -c 'until [ -f x ]; do sleep 5; done'",
    ),
    (
        BLOCKED,
        "a poll in sh -c is blocked",
        "sh -c 'while pgrep foo; do sleep 2; done'",
    ),
    (BLOCKED, "a long sleep in bash -c is blocked", "bash -c 'sleep 30'"),
    (
        BLOCKED,
        "a poll in bash -lc is blocked",
        "bash -lc 'until [ -f x ]; do sleep 5; done'",
    ),
    (
        BLOCKED,
        "a poll in bash with options before -c is blocked",
        "bash -euo pipefail -c 'until [ -f x ]; do sleep 5; done'",
    ),
    (
        BLOCKED,
        "a poll under timeout is blocked",
        "timeout 590 bash -c 'until [ -f x ]; do sleep 5; done'; cat log",
    ),
    (
        BLOCKED,
        "a poll under nix develop is blocked",
        "nix develop .#ci -c bash -c 'until [ -f x ]; do sleep 5; done'",
    ),
    (
        BLOCKED,
        "a poll under timeout and nix develop is blocked",
        "timeout 600 nix develop -c bash -c 'sleep 30'",
    ),
    (
        BLOCKED,
        "a poll after an assignment is blocked",
        "D=/tmp bash -c 'until [ -f x ]; do sleep 5; done'",
    ),
    (BLOCKED, "a long sleep under timeout is blocked", "timeout 60 sleep 30"),
    (BLOCKED, "a wait after a flake reference is blocked", "nix build .#foo; sleep 30"),
    (
        BLOCKED,
        "a wait after a flake reference in bash -c is blocked",
        "bash -c 'nix build .#foo; sleep 30'",
    ),
    (
        BLOCKED,
        "a double-quoted bash -c keeps its flake reference apart",
        'bash -c "nix build .#foo; sleep 30"',
    ),
    (
        BLOCKED,
        "a nested bash -c keeps its flake reference apart",
        "bash -c \"bash -c 'nix build .#foo; sleep 30'\"",
    ),
    (
        BLOCKED,
        "an until around a bash -c condition is blocked",
        "until bash -c 'test -f x'; do sleep 5; done",
    ),
    (
        BLOCKED,
        "a while around a wrapped condition is blocked",
        "while timeout 60 bash -c 'pgrep foo'; do sleep 2; done",
    ),
    (BLOCKED, "a long sleep under nohup is blocked", "nohup sleep 30"),
    (
        BLOCKED,
        "a poll under env is blocked",
        "env -i A=1 bash -c 'until [ -f x ]; do sleep 5; done'",
    ),
    (BLOCKED, "a long sleep under command is blocked", "command sleep 30"),
    (BLOCKED, "tail -f is blocked", "tail -f build.log"),
    (BLOCKED, "tail -F is blocked", "tail -F build.log"),
    (BLOCKED, "tail --follow is blocked", "tail --follow build.log"),
    (BLOCKED, "tail --follow=name is blocked", "tail --follow=name build.log"),
    (BLOCKED, "tail with -f in a flag cluster is blocked", "tail -fn 20 build.log"),
    (
        BLOCKED,
        "tail -f piped into a filter is blocked",
        "tail -n +1 -f build.log | grep -m1 ^EXIT",
    ),
    (BLOCKED, "tail -f on a pid is blocked", 'tail --pid="$P" -f /dev/null'),
    (
        BLOCKED,
        "tail -f under timeout is blocked",
        "timeout 590 tail -n +1 -f build.log | grep -m1 done",
    ),
    (BLOCKED, "tail -f in bash -c is blocked", "bash -c 'tail -f build.log'"),
    (BLOCKED, "tail -f before && is blocked", "tail -f build.log && just build"),
    (
        BLOCKED,
        "a wait after a backgrounded tail -f is blocked",
        "tail -f build.log & sleep 30",
    ),
    (
        BLOCKED,
        "a bash -c script that does not parse keeps the outer verdict",
        "sleep 30; bash -c 'x('",
    ),
    (
        BLOCKED,
        "a loop of bash -c scripts that do not parse is still a loop",
        "while bash -c 'x('; do bash -c 'y('; done; sleep 2",
    ),
    (ALLOWED, "a bash -c script that does not parse is allowed alone", "bash -c 'x('"),
    (
        ALLOWED,
        "a tail -f sent to the background with & is allowed",
        "tail -f build.log & just build; kill %1",
    ),
    (ALLOWED, "a commented-out wait is allowed", "ls # sleep 30"),
    (ALLOWED, "a one-shot script in bash -c is allowed", "bash -c 'echo hi; ls'"),
    (ALLOWED, "a commented-out wait in bash -c is allowed", "bash -c 'ls # sleep 30'"),
    (
        ALLOWED,
        "a bash -c in a loop without a sleep is allowed",
        "while read l; do bash -c 'echo hi'; done < f",
    ),
    (
        ALLOWED,
        "a short sleep after a bash -c condition is allowed",
        "if bash -c 'true'; then sleep 2; fi",
    ),
    (ALLOWED, "a short sleep in bash -c is allowed", "bash -c 'sleep 2'"),
    (
        ALLOWED,
        "a build under nix develop is allowed",
        "nix develop -c bash -c 'just test'",
    ),
    (ALLOWED, "a command under timeout is allowed", "timeout 600 just test"),
    (ALLOWED, "a short timeout bounds tail -f", "timeout 4 tail -f build.log"),
    (
        ALLOWED,
        "a short timeout bounds a poll",
        "timeout 5 bash -c 'until [ -f x ]; do sleep 1; done'",
    ),
    (ALLOWED, "tail -n is allowed", "tail -n 20 build.log"),
    (ALLOWED, "tail -c is allowed", "tail -c 100 build.log"),
    (ALLOWED, "tail on a file named after the flag is allowed", "tail -n 5 -- f"),
    (ALLOWED, "a plain tail is allowed", "tail build.log"),
    (ALLOWED, "a tail in a pipe is allowed", "just test | tail -20"),
    (
        ALLOWED,
        "a -f on another command is allowed",
        "rm -f build.log; grep -f patterns log",
    ),
    (
        ALLOWED,
        "a wrapper named in a string is allowed",
        "echo \"bash -c 'sleep 30'\" && git commit -m 'tail -f log'",
    ),
    (BLOCKED, "a sleep split by a line continuation is blocked", "sleep \\\n60"),
    (BLOCKED, "a tail -f split by a line continuation is blocked", "tail \\\n-f log"),
    (BLOCKED, "a sleep in backticks is blocked", "echo `sleep 60`"),
    (
        BLOCKED,
        "a sleep in a quoted substitution is blocked",
        'echo "$(cat big; sleep 60)"',
    ),
    (BLOCKED, "a sleep in a process substitution is blocked", "cat <(sleep 60)"),
    (
        BLOCKED,
        "a substitution in an unquoted heredoc body runs, so it is blocked",
        "cat <<EOF\n$(sleep 60)\nEOF",
    ),
    (
        BLOCKED,
        "a comment after a mid-word hash hides no next line",
        "echo a#b # comment\nsleep 12",
    ),
    (BLOCKED, "a sleep in a coproc is blocked", "coproc sleep 60"),
    (
        ALLOWED,
        "a substitution in a quoted heredoc body is text, so it is allowed",
        "cat <<\\EOF\n$(sleep 60)\nEOF",
    ),
    (
        ALLOWED,
        "a short sleep in a for loop is allowed",
        "for i in 1 2; do sleep 1; done",
    ),
    (
        ALLOWED,
        "a short sleep in an arithmetic for loop is allowed",
        "for ((i = 0; i < 2; i++)); do sleep 1; done",
    ),
    (
        ALLOWED,
        "a short sleep in a select loop is allowed",
        "select x in a b; do sleep 1; done",
    ),
]

BACKGROUND_CASES: list[Case[str]] = [
    (ALLOWED, "a backgrounded long sleep is allowed", "sleep 30"),
    (ALLOWED, "a backgrounded poll is allowed", "until [ -f x ]; do sleep 5; done"),
    (ALLOWED, "a backgrounded tail -f is allowed", "tail -f build.log"),
    (
        ALLOWED,
        "a backgrounded bash -c poll is allowed",
        "bash -c 'until [ -f x ]; do sleep 5; done'",
    ),
]

AGENT_CASES: list[Case[tuple[str | None, str, bool]]] = [
    (
        BLOCKED,
        "a repeated read in a substitution is blocked",
        ("fresh", 'a="$(gh pr checks 7)"; b="$(gh pr checks 7)"', False),
    ),
    (
        BLOCKED,
        "a second read of the same checks is blocked",
        ("polled", "gh pr checks 7", False),
    ),
    (
        BLOCKED,
        "a second read with other flags is blocked",
        ("polled", "gh pr checks 7 --json state", False),
    ),
    (
        BLOCKED,
        "a repeated read behind a value flag is blocked",
        ("polled", "gh pr checks --repo o/r 7", False),
    ),
    (
        ALLOWED,
        "another pull request's checks are allowed",
        ("polled", "gh pr checks 8", False),
    ),
    (
        ALLOWED,
        "another pull request behind a value flag is allowed",
        ("polled", "gh pr checks --repo o/r 8", False),
    ),
    (
        ALLOWED,
        "another pull request behind a value flag with = is allowed",
        ("polled", "gh pr checks --repo=o/r 8", False),
    ),
    (
        ALLOWED,
        "a repeated command that is not CI is allowed",
        ("polled", "git status", False),
    ),
    (
        ALLOWED,
        "a first read is allowed, though the transcript holds the call itself",
        ("fresh", "gh pr checks 7", False),
    ),
    (
        ALLOWED,
        "a log read is allowed",
        ("fresh", "gh run view 12 --log-failed | rg error", False),
    ),
    (ALLOWED, "a one-shot run status is allowed", ("fresh", "gh run view 12", False)),
    (
        ALLOWED,
        "a status read after a loop is allowed",
        ("fresh", 'for f in a b; do ls "$f"; done; gh pr checks 7', False),
    ),
    (
        ALLOWED,
        "a status read after a loop around bash -c is allowed",
        ("fresh", "until bash -c 'a; b'; do ls; done; gh pr checks 7", False),
    ),
    (
        ALLOWED,
        "watch over something else is allowed",
        ("fresh", "watch -n 30 ls", False),
    ),
    (
        BLOCKED,
        "gh pr checks --watch is blocked",
        ("fresh", "gh pr checks 7 --watch", False),
    ),
    (
        BLOCKED,
        "gh pr checks --watch in the background is blocked",
        ("fresh", "gh pr checks 7 --watch", True),
    ),
    (BLOCKED, "gh run watch is blocked", ("fresh", "gh run watch 12", False)),
    (
        BLOCKED,
        "gh run watch under timeout is blocked",
        ("fresh", "timeout 300 gh run watch 12", False),
    ),
    (
        BLOCKED,
        "gh run watch in nix develop is blocked",
        ("fresh", "nix develop -c bash -c 'gh run watch 12'", False),
    ),
    (
        BLOCKED,
        "a polling loop in the background is blocked",
        ("fresh", "until gh pr checks 7; do sleep 30; done", True),
    ),
    (
        BLOCKED,
        "a for loop over a read is blocked",
        ("fresh", "for i in 1 2 3; do gh run view 12; sleep 30; done", True),
    ),
    (
        BLOCKED,
        "a read after a sleep in a loop body is blocked",
        ("fresh", "while true; do sleep 30; gh pr checks 7; done", True),
    ),
    (
        BLOCKED,
        "a read deep in a for body is blocked",
        ("fresh", "for i in 1 2; do ls; gh pr checks 7; done", False),
    ),
    (
        BLOCKED,
        "a read deep in an until body is blocked",
        ("fresh", "until false; do ls; gh run list; done", True),
    ),
    (
        BLOCKED,
        "a read in a loop in bash -c is blocked",
        ("fresh", "bash -c 'while true; do sleep 30; gh pr checks 7; done'", True),
    ),
    (
        BLOCKED,
        "a read in bash -c in a loop is blocked",
        ("fresh", "while true; do sleep 30; bash -c 'gh pr checks 7'; done", True),
    ),
    (
        BLOCKED,
        "a read after an inner loop of an outer one is blocked",
        ("fresh", "while true; do for i in 1; do ls; done; gh pr checks 7; done", True),
    ),
    (
        ALLOWED,
        "a finite loop over failed logs is allowed",
        (
            "fresh",
            'for r in 12 13; do gh run view "$r" --log-failed | rg error; done',
            False,
        ),
    ),
    (
        ALLOWED,
        "a loop in the background over a log is allowed",
        ("fresh", 'while read r; do gh run view "$r" --log; done < runs', True),
    ),
    (BLOCKED, "watch over a read is blocked", ("fresh", "watch gh pr checks 7", False)),
    (
        BLOCKED,
        "watch with an interval is blocked",
        ("fresh", "watch -n 30 'gh pr checks 7'", False),
    ),
    (
        BLOCKED,
        "watch under timeout in the background is blocked",
        ("fresh", "timeout 300 watch -n 30 gh run list", True),
    ),
    (
        BLOCKED,
        "gh run watch under env is blocked",
        ("fresh", "env A=1 gh run watch 12", False),
    ),
    (
        BLOCKED,
        "gh pr checks --watch under nohup is blocked",
        ("fresh", "nohup gh pr checks 7 --watch", False),
    ),
    (
        BLOCKED,
        "gh run watch under command is blocked",
        ("fresh", "command gh run watch 12", False),
    ),
    (
        BLOCKED,
        "two reads in one command are blocked",
        ("fresh", "gh pr checks 7; sleep 5; gh pr checks 7", False),
    ),
    (
        ALLOWED,
        "reads of two pull requests in one command are allowed",
        ("fresh", "gh pr checks 7; gh pr checks 8", False),
    ),
    (
        ALLOWED,
        "a subagent with no transcript yet may read once",
        ("missing", "gh pr checks 7", False),
    ),
    (
        BLOCKED,
        "a subagent with no transcript still may not watch",
        ("missing", "gh run watch 12", False),
    ),
    (
        BLOCKED,
        "a subagent with no transcript still may not loop",
        ("missing", "until gh pr checks 7; do sleep 30; done", True),
    ),
    (ALLOWED, "main may read checks again", (None, "gh pr checks 7", False)),
    (
        ALLOWED,
        "main may watch in the background",
        (None, "gh pr checks 7 --watch", True),
    ),
    (ALLOWED, "main may run gh run watch", (None, "gh run watch 12", False)),
]

RAW_CASES: list[Case[str]] = [
    (
        BLOCKED,
        "an event with no transcript_path is still judged on its command",
        '{"agent_id": "a", "tool_input": {"command": "sleep 60"}}',
    ),
    (
        ALLOWED,
        "a status read with no transcript_path fails open",
        '{"agent_id": "a", "tool_input": {"command": "gh pr checks 7"}}',
    ),
]


@guard_cases(FOREGROUND_CASES)
def test_foreground_call(want: int, given: str) -> None:
    assert run_guard([GUARD], bash_event(given)).returncode == want


@guard_cases(BACKGROUND_CASES)
def test_background_call(want: int, given: str) -> None:
    assert run_guard([GUARD], bash_event(given, background=True)).returncode == want


@guard_cases(AGENT_CASES)
def test_agent_call(
    session: Path, want: int, given: tuple[str | None, str, bool]
) -> None:
    agent, command, background = given

    result = run_guard(
        [GUARD], agent_call(session, agent, command, background=background)
    )

    assert result.returncode == want


@guard_cases(RAW_CASES + FAIL_OPEN_CASES)
def test_raw_input(want: int, given: str) -> None:
    assert run_guard([GUARD], given).returncode == want


@pytest.mark.parametrize(
    "earlier",
    [
        "cd sub && gh pr checks 7 | tail -5",
        "gh pr \\\n  checks 7",
        "bash -c 'gh pr checks 7'",
        'echo "$(gh pr checks 7)"',
        "nix develop -c gh pr checks 7",
    ],
)
def test_an_earlier_status_read_counts_among_other_commands(
    tmp_path: Path, earlier: str
) -> None:
    lines = "".join(
        [
            bash_line("ls", "before"),
            bash_line(earlier, "old"),
            bash_line("git status", "after"),
            bash_line("gh pr checks 7", "now"),
        ]
    )
    transcript = session_with(tmp_path, "", {"agent": lines})

    result = run_guard([GUARD], agent_call(transcript, "agent", "gh pr checks 7"))

    assert result.returncode == BLOCKED


def test_a_working_shfmt_blocks_on_the_runner_of_the_broken_ones() -> None:
    argv = guard_on(SOURCE, bash_commands.SHFMT)

    assert run_guard(argv, bash_event("sleep 30")).returncode == BLOCKED


@guard_cases(BROKEN_SHFMT)
def test_a_broken_shfmt_allows_a_wait(
    tmp_path: Path, want: int, given: BrokenShfmt
) -> None:
    result = run_guard(guard_on_broken(SOURCE, given, tmp_path), bash_event("sleep 30"))

    assert (result.returncode, result.stderr) == (want, "")


def test_a_working_shfmt_blocks_a_repeated_read_on_that_runner(session: Path) -> None:
    argv = guard_on(SOURCE, bash_commands.SHFMT)

    result = run_guard(argv, agent_call(session, "polled", "gh pr checks 7"))

    assert result.returncode == BLOCKED


@guard_cases(BROKEN_SHFMT)
def test_a_broken_shfmt_allows_a_repeated_read(
    tmp_path: Path, session: Path, want: int, given: BrokenShfmt
) -> None:
    result = run_guard(
        guard_on_broken(SOURCE, given, tmp_path),
        agent_call(session, "polled", "gh pr checks 7"),
    )

    assert (result.returncode, result.stderr) == (want, "")


def test_a_block_says_to_background_and_when_to_hand_back() -> None:
    result = run_guard([GUARD], bash_event("sleep 30"))

    assert result.returncode == BLOCKED
    assert "run_in_background" in result.stderr
    assert "about 60k context" in result.stderr


def test_a_repeated_read_says_a_subagent_never_waits_on_ci(session: Path) -> None:
    result = run_guard([GUARD], agent_call(session, "polled", "gh pr checks 7"))

    assert result.returncode == BLOCKED
    assert "never waits on CI" in result.stderr


@pytest.fixture(scope="module")
def session(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """The main transcript, with one read of checks by main, by `polled` and by `fresh`.

    `polled` read twice: the transcript holds a call the moment its hook runs,
    so its second line, `now`, is the call under test, and `old` the earlier one.
    """
    read = "gh pr checks 7"
    return session_with(
        tmp_path_factory.mktemp("session"),
        bash_line(read, "old"),
        {
            "polled": bash_line(read, "old") + bash_line(read, "now"),
            "fresh": bash_line(read, "now"),
        },
    )


def bash_line(command: str, use_id: str) -> str:
    """An assistant transcript line with one Bash call."""
    call = {
        "type": "tool_use",
        "id": use_id,
        "name": "Bash",
        "input": {"command": command},
    }
    message = {"id": use_id, "content": [call]}
    return json.dumps({"type": "assistant", "message": message}) + "\n"


def agent_call(
    session: Path, agent: str | None, command: str, *, background: bool = False
) -> str:
    return bash_event(
        command,
        background=background,
        tool_use_id="now",
        transcript_path=str(session),
        **agent_fields(agent),
    )
