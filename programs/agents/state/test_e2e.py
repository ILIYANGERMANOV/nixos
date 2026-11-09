"""The built `state` command, end to end: the wrapped binary the agents get on
PATH, run as a process on a temp git repo. No module of the program is imported,
so this proves the packaging - the wrapper, the package path, the entry point -
as well as the flow. `python-tests` puts the binary in $STATE, and the hooks'
entry point, `state-hook`, in $STATE_HOOK, which the frontend's dispatcher
(agent_hook.py) runs as the agents' backends do."""

import json
import os
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import cast

from agent_hook import (
    AfterTool,
    Hook,
    HookName,
    JsonObject,
    Note,
    SessionId,
    Tool,
    dispatch_note,
    run_note_hook,
)

from state.state_fixtures import PR, commit

STATE = os.environ["STATE"]
STATE_HOOK = os.environ["STATE_HOOK"]


def state(repo: Path, *argv: str, stdin: str | None = None) -> tuple[int, str, str]:
    done = subprocess.run(
        [STATE, *argv],
        cwd=repo,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    return done.returncode, done.stdout, done.stderr


def ok(repo: Path, *argv: str, stdin: str | None = None) -> str:
    code, out, err = state(repo, *argv, stdin=stdin)
    assert (code, err) == (0, ""), err
    return out


def drafted(repo: Path, notes: Path) -> None:
    """A delegated run up to Impl: its knobs set and draft PR 7 against main."""
    knobs_set(repo, notes)
    _ = ok(repo, "record", "drafted", PR, "main")


def knobs_set(repo: Path, notes: Path) -> None:
    """A delegated run with its size and quality set, its draft PR to come."""
    _ = ok(repo, "init", "--notes", str(notes), "--delegated")
    _ = ok(repo, "record", "size", "Normal")
    _ = ok(repo, "record", "quality", "Balanced")


def test_a_run_goes_from_init_through_a_handback_to_the_review(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"

    _ = ok(repo, "init", "--notes", str(notes), "--delegated")
    recorded = ok(repo, "record", "size", "Normal")
    _ = ok(repo, "record", "quality", "Balanced")
    to_impl = ok(repo, "record", "drafted", PR, "main")
    first = ok(repo, "next")
    head = commit(repo, {"b.txt": "two\n"}, "implement")
    handed = ok(repo, "handback", "implementer", stdin=f"READY {PR}\ndone\n")
    second = ok(repo, "next")
    shown = ok(repo, "show")

    assert (notes / "events.jsonl").is_file()
    assert recorded == "recorded 2 size -> DraftPlan\n"
    assert to_impl == "recorded 4 drafted -> Impl\n"
    assert first.splitlines()[0] == "SPAWN implementer"
    assert handed == "recorded 5 implemented -> Impl'\n"
    assert second.splitlines()[0] == "SPAWN review-lead"
    assert "Step: Impl'" in shown.splitlines()
    assert f"Head: {head}" in shown.splitlines()


def test_override_moves_off_the_advised_arrow_and_next_follows_it(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")

    moved = ok(repo, "override", "PR", "skip the review")
    advice = ok(repo, "next")

    assert moved == "recorded 5 overridden -> PR\n"
    assert advice.splitlines()[0] == "WAIT ci"


def test_override_to_an_unknown_state_exits_2_listing_the_states(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")

    code, out, err = state(repo, "override", "Bogus", "why")

    assert (code, out) == (2, "")
    assert err.splitlines()[0] == "state override: no state 'Bogus'"
    assert err.splitlines()[1].startswith("fix: states: Ctx ")


def test_a_hand_edited_bad_line_exits_2_naming_the_line(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    drafted(repo, notes)
    log = notes / "events.jsonl"
    _ = log.write_text(log.read_text() + "{bad\n")

    code, out, err = state(repo, "show")

    assert (code, out) == (2, "")
    assert err.startswith(f"state: {log}:5: not JSON")
    assert f"fix: repair or delete line 5 of {log}" in err


def hook(repo: Path, name: str, event: Mapping[str, object]) -> dict[str, object]:
    """One neutral-contract event through `state-hook <name>`; its result."""
    stdin = json.dumps({"session": "s", "cwd": str(repo), "agent": None, **event})
    done = subprocess.run(
        [STATE_HOOK, name],
        cwd=repo,
        input=stdin,
        capture_output=True,
        text=True,
        check=True,
    )
    assert done.stderr == ""
    return cast("dict[str, object]", json.loads(done.stdout)) if done.stdout else {}


STARTED = {"event": "sessionStart", "source": "startup"}


def test_the_resume_hook_prints_nothing_with_no_run(repo: Path) -> None:
    told = hook(repo, "resume", STARTED)

    assert told == {}


def test_the_resume_hook_tells_the_step_of_a_run(repo: Path, tmp_path: Path) -> None:
    drafted(repo, tmp_path / "notes")

    told = hook(repo, "resume", STARTED)

    assert str(told["context"]).startswith("Step: Impl\n")


def test_the_spawn_hook_gives_a_fixer_the_branch_diff_folder(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")

    # `ctx` is on the wrapper's PATH.
    spawned = hook(
        repo,
        "spawn",
        {
            "event": "beforeTool",
            "tool": "delegate",
            "input": {"prompt": "Fix it.", "subagent_type": "fixer"},
        },
    )

    match spawned["updatedInput"]:
        case {"prompt": str(prompt)}:
            pass
        case other:
            raise AssertionError(f"no prompt rewritten: {other!r}")
    assert prompt.startswith("Fix it.\nDiff: /")
    assert Path(prompt.removeprefix("Fix it.\nDiff: ")).joinpath("diff").is_file()


def test_the_handback_hook_records_the_handback_and_tells_the_worker(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "two\n"}, "implement")

    handed = hook(
        repo,
        "handback",
        {
            "event": "beforeTool",
            "tool": "handback",
            "agent": {"id": "a1", "role": "implementer"},
            "input": {"message": "READY done"},
        },
    )

    assert handed["updatedInput"] == {
        "message": "READY done\n\nstate: recorded 5 implemented -> Impl'"
    }


# The `pr` hook as the base profile declares it (hooks.nix), dispatched.
STATE_PR = Hook(HookName("state-pr"), frozenset({Tool.SHELL}), (STATE_HOOK, "pr"))


def ran(repo: Path, command: str, stdout: str) -> Note:
    """The lead's shell call, after it ran, through the dispatcher."""
    output: JsonObject = {"stdout": stdout, "stderr": "", "interrupted": False}
    event = AfterTool(
        SessionId("s"), repo, None, Tool.SHELL, {"command": command}, output
    )
    return dispatch_note([STATE_PR], event, run_note_hook)


def last_event(notes: Path) -> object:
    lines = (notes / "events.jsonl").read_text().splitlines()
    return cast("dict[str, object]", json.loads(lines[-1]))["event"]


def test_the_pr_hook_records_the_draft_gh_pr_create_printed(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    knobs_set(repo, notes)

    told = ran(repo, "gh pr create --draft --base main --fill", f"{PR}\n")

    assert told == Note("state: recorded 4 drafted -> Impl")
    assert last_event(notes) == {"type": "drafted", "url": PR, "base": "main"}


def test_the_pr_hook_records_gh_pr_ready_with_the_drafted_url(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    drafted(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")

    told = ran(repo, "gh pr ready", "")

    assert told == Note("state: recorded 6 ready -> Done")
    assert last_event(notes) == {"type": "ready", "url": PR}
