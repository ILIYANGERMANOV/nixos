"""The hooks end to end, as opencode-kategory deploys them: the plugin's
envelopes through the built adapter and the profile's manifest, so the real
`state-hook` and guards: the gate that holds a lead's edits until its run
exists, the guards' denies, the context notice and a task's hand-back."""

import json
import os
import subprocess
from pathlib import Path
from typing import cast

import pytest
from agent_hook import Json, JsonObject
from plugin_envelopes import (
    CHILD,
    LEAD,
    after,
    before,
    call_tokens,
    envelope,
    in_child,
    task_output,
)

ADAPTER = os.environ["AGENT_HOOK_OPENCODE"]
TOOLS_FILE = os.environ["AGENT_HOOK_OPENCODE_TOOLS"]
MANIFEST = Path(os.environ["AGENT_HOOK_OPENCODE_MANIFEST"])

# opencode-kategory ships no secret files, so its profile has no secret guard:
# the guard is declared here as a host with one would get it (guards/hooks.nix).
QA_KEY_FILE = "/run/secrets/qa-sepolia-key"
SECRET_GUARD: JsonObject = {
    "name": "secret-guard",
    "tools": ["shell"],
    "command": [
        os.environ["SECRET_GUARD"],
        json.dumps({"paths": [QA_KEY_FILE], "vars": ["QA_SEPOLIA_KEY"]}),
    ],
}


@pytest.fixture(autouse=True)
def own_state_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Each test's hooks keep their agents' bindings to runs apart."""
    state_home = tmp_path / "state-home"
    monkeypatch.setenv("XDG_STATE_HOME", str(state_home))
    return state_home


# ---- The kernel's gate ---------------------------------------------------------------


def test_a_lead_edit_waits_for_its_run(tmp_path: Path) -> None:
    own = worktree(tmp_path / "own")
    _ = answer(envelope("command", own, command="engineer"))

    told = answer(edit(own))

    assert "this lead has no run" in cast("str", told["deny"])


def test_a_lead_edit_goes_on_once_its_state_init_ran(tmp_path: Path) -> None:
    own = worktree(tmp_path / "own")
    _ = answer(envelope("command", own, command="engineer"))
    _ = answer(
        ran_shell(
            own,
            f"state init --notes {tmp_path}/notes/ --task t2",
            f"run 0a1b2c3d {tmp_path}/notes {own}\n",
        )
    )

    assert "deny" not in answer(edit(own))


def test_a_finished_tasks_hand_back_reaches_the_kernel(
    tmp_path: Path, own_state_home: Path
) -> None:
    task = task_output("completed", "READY abc")
    args: JsonObject = {
        "description": "d",
        "prompt": "p",
        "subagent_type": "implementer",
    }

    _ = answer(after("task", args, task, directory=tmp_path))

    # The lead is bound to no run, so the kernel keeps the hand-back for the
    # child's binding (State.Protocol.Binding).
    stash = own_state_home / "state" / "bindings" / LEAD / f"handback-{CHILD}.json"
    assert json.loads(stash.read_text())["input"] == {"message": "READY abc"}


# ---- The guards ---------------------------------------------------------------------------


def test_a_long_foreground_sleep_is_denied_with_the_wait_hint(tmp_path: Path) -> None:
    told = answer(shell(tmp_path, "sleep 60"))

    assert "waits in the foreground" in cast("str", told["deny"])


def test_a_large_cat_is_denied_with_the_read_hint(tmp_path: Path) -> None:
    _ = (tmp_path / "huge").write_bytes(bytes(20_000))

    told = answer(shell(tmp_path, "cat huge"))

    assert "rg -n first" in cast("str", told["deny"])


def test_an_unbounded_read_of_a_large_file_is_denied_with_the_read_hint(
    tmp_path: Path,
) -> None:
    huge = tmp_path / "huge"
    _ = huge.write_bytes(bytes(20_000))

    told = answer(before("read", {"filePath": str(huge)}, directory=tmp_path))

    assert "rg -n first" in cast("str", told["deny"])


def test_a_bounded_read_of_a_large_file_goes_on(tmp_path: Path) -> None:
    huge = tmp_path / "huge"
    _ = huge.write_bytes(bytes(20_000))
    args: JsonObject = {"filePath": str(huge), "offset": 1, "limit": 20}

    assert answer(before("read", args, directory=tmp_path)) == {}


def test_a_subagents_ci_watch_is_denied(tmp_path: Path) -> None:
    told = answer(in_child(shell(tmp_path, "gh pr checks 7 --watch")))

    assert "never waits on CI" in cast("str", told["deny"])


def test_a_subagents_status_read_it_made_before_is_denied(tmp_path: Path) -> None:
    told = answer(in_child(shell(tmp_path, "gh run view 7", ["gh run view 7"])))

    assert "never waits on CI" in cast("str", told["deny"])


def test_a_secret_path_is_denied(tmp_path: Path) -> None:
    manifest = cast("dict[str, list[Json]]", json.loads(MANIFEST.read_text()))
    with_secrets = tmp_path / "manifest.json"
    _ = with_secrets.write_text(
        json.dumps(manifest | {"beforeTool": [SECRET_GUARD, *manifest["beforeTool"]]})
    )

    told = answer(shell(tmp_path, f"cat {QA_KEY_FILE}"), with_secrets)

    assert "Never read it from a shell" in cast("str", told["deny"])


def test_crossing_300k_gives_the_lead_the_notice(tmp_path: Path) -> None:
    tokens = [call_tokens(1_000, read=297_000), call_tokens(500, read=300_000)]

    told = answer(after("glob", {"pattern": "*"}, "a.py", tokens, directory=tmp_path))

    assert "Context 300k" in cast("str", told["context"])


# ---- The plugin's side ------------------------------------------------------------------


def answer(payload: JsonObject, manifest: Path = MANIFEST) -> JsonObject:
    """What the plugin reads back from the profile's hooks for `payload`."""
    done = subprocess.run(
        [ADAPTER, TOOLS_FILE, str(manifest)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )
    assert (done.returncode, done.stderr) == (0, ""), done.stderr
    return cast("JsonObject", json.loads(done.stdout))


def shell(
    directory: Path, command: str, history: list[str] | None = None
) -> JsonObject:
    return before("bash", {"command": command}, history or [], directory)


def ran_shell(directory: Path, command: str, output: str) -> JsonObject:
    return after("bash", {"command": command}, output, directory=directory)


def edit(directory: Path) -> JsonObject:
    args: JsonObject = {
        "filePath": str(directory / "a.py"),
        "oldString": "x",
        "newString": "y",
    }
    return before("edit", args, directory=directory)


def worktree(path: Path) -> Path:
    """A fresh git worktree at `path`, as git names its top."""
    _ = subprocess.run(["git", "init", "-q", str(path)], check=True)
    return path.resolve()
