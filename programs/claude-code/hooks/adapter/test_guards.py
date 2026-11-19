"""The hooks end to end, as each flavor deploys them: Claude's hook JSON, shaped
as the contract snapshot or the live probe recorded it, through the hook
commands its settings.json holds, against a transcript on disk: the guards, and
the state hooks that bind an agent to its run, deny a `state` call at another
run and tell how work begins."""

import json
import os
import re
import subprocess
from pathlib import Path
from typing import cast

import pytest
from agent_hook import JsonObject
from recorded_events import recorded
from transcript_fixtures import bash, model_call, write_transcript

# Flavor name -> its settings.json, as installed.
SETTINGS = cast("dict[str, str]", json.loads(os.environ["CLAUDE_SETTINGS"]))
CONTRACT = Path(__file__).parents[1] / "contract"
SNAPSHOT = cast("JsonObject", json.loads((CONTRACT / "snapshot.json").read_text()))

# The synthetic secret file every test build gives the base profile.
QA_KEY_FILE = "/run/secrets/qa-sepolia-key"
WORKER = "a1b2"

flavors = pytest.mark.parametrize("flavor", sorted(SETTINGS))


@pytest.fixture(autouse=True)
def own_state_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Each test's hooks keep their agents' bindings to runs apart."""
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state-home"))


@flavors
def test_a_long_foreground_sleep_is_denied_with_the_wait_hint(
    flavor: str, tmp_path: Path
) -> None:
    told = denied(flavor, shell_call(tmp_path, "sleep 60"))

    assert "run_in_background" in told


@flavors
def test_a_large_cat_is_denied_with_the_read_hint(flavor: str, tmp_path: Path) -> None:
    _ = (tmp_path / "huge").write_bytes(bytes(20_000))

    told = denied(flavor, shell_call(tmp_path, "cat huge"))

    assert "rg -n first" in told


@flavors
def test_a_call_two_guards_deny_tells_both_hints(flavor: str, tmp_path: Path) -> None:
    _ = (tmp_path / "huge").write_bytes(bytes(20_000))

    told = denied(flavor, shell_call(tmp_path, "cat huge; sleep 60"))

    assert "rg -n first" in told
    assert "run_in_background" in told


@flavors
def test_a_secret_path_is_denied(flavor: str, tmp_path: Path) -> None:
    told = denied(flavor, shell_call(tmp_path, f"cat {QA_KEY_FILE}"))

    assert "Never read it from a shell" in told


@flavors
def test_a_subagents_ci_watch_is_denied(flavor: str, tmp_path: Path) -> None:
    told = denied(flavor, shell_call(tmp_path, "gh pr checks 7 --watch", agent=WORKER))

    assert "never waits on CI" in told


@flavors
def test_a_subagents_one_shot_ci_read_after_an_earlier_one_is_allowed(
    flavor: str, tmp_path: Path
) -> None:
    write_transcript(
        worker_transcript(tmp_path),
        model_call("m1", 1_000, bash("toolu_m1", "gh pr checks 7")),
    )

    payload = shell_call(tmp_path, "gh pr checks 7", agent=WORKER)

    assert answer(flavor, "PreToolUse", payload) == {}


@flavors
def test_the_leads_second_ci_read_is_allowed(flavor: str, tmp_path: Path) -> None:
    write_transcript(
        lead_transcript(tmp_path),
        model_call("m1", 1_000, bash("toolu_m1", "gh pr checks 7")),
    )

    assert answer(flavor, "PreToolUse", shell_call(tmp_path, "gh pr checks 7")) == {}


@flavors
def test_crossing_300k_after_an_mcp_tool_gives_the_notice(
    flavor: str, tmp_path: Path
) -> None:
    write_transcript(
        lead_transcript(tmp_path),
        [
            *model_call("m1", 298_000, bash("toolu_m1", "ls")),
            *model_call("m2", 300_500, bash("toolu_m2", "ls")),
        ],
    )

    output = answer(flavor, "PostToolUse", mcp_result(tmp_path))

    assert "Context 300k" in additional_context(output)


@flavors
def test_a_subagent_claude_names_no_id_still_runs_the_guards(
    flavor: str, tmp_path: Path
) -> None:
    no_id = shell_call(tmp_path, f"cat {QA_KEY_FILE}", agent=WORKER) | {
        "agent_id": None
    }

    assert "Never read it from a shell" in denied(flavor, no_id)


@flavors
def test_a_state_call_at_another_run_than_the_agents_is_denied_with_the_fix(
    flavor: str, tmp_path: Path
) -> None:
    own, foreign = bound_engineer(flavor, tmp_path)

    told = denied(
        flavor, shell_call(foreign, "state next", agent=WORKER, role="engineer")
    )

    assert f"fix: cd {own} && state next" in told


@flavors
def test_a_state_call_in_the_agents_own_worktree_is_allowed(
    flavor: str, tmp_path: Path
) -> None:
    own, foreign = bound_engineer(flavor, tmp_path)

    payload = shell_call(
        foreign, f"cd {own} && state next", agent=WORKER, role="engineer"
    )

    assert answer(flavor, "PreToolUse", payload) == {}


@flavors
@pytest.mark.parametrize(
    ("role", "said"),
    [
        ("engineer", "the `state init` line"),
        ("implementer", "A question that blocks your work"),
    ],
)
def test_a_spawned_engineer_or_worker_is_told_how_its_work_begins(
    flavor: str, tmp_path: Path, role: str, said: str
) -> None:
    started = recorded("SubagentStart") | {"cwd": str(tmp_path), "agent_type": role}

    assert said in additional_context(answer(flavor, "SubagentStart", started))


@flavors
def test_a_spawned_agent_of_no_state_role_is_told_nothing(
    flavor: str, tmp_path: Path
) -> None:
    started = recorded("SubagentStart") | {"cwd": str(tmp_path)}

    assert answer(flavor, "SubagentStart", started) == {}


@flavors
def test_a_typed_engineer_skill_is_told_it_begins_with_state(
    flavor: str, tmp_path: Path
) -> None:
    typed = recorded("UserPromptExpansion") | {
        "cwd": str(tmp_path),
        "command_name": "engineer",
        "prompt": "/engineer fix it",
    }

    told = additional_context(answer(flavor, "UserPromptExpansion", typed))

    assert "`state init ...`" in told


@flavors
def test_a_called_engineer_skill_is_told_it_begins_with_state(
    flavor: str, tmp_path: Path
) -> None:
    skill: JsonObject = {
        "tool_name": "Skill",
        "tool_input": {"skill": "10x-engineer", "args": "fix it"},
    }

    told = additional_context(
        answer(flavor, "PreToolUse", shell_call(tmp_path, "") | skill)
    )

    assert "`state init ...`" in told


# ---- Claude's side ------------------------------------------------------------------


def answer(flavor: str, event: str, payload: JsonObject) -> JsonObject:
    """What Claude reads back from the flavor's hooks for `payload`."""
    commands = hook_commands(flavor, event, matched_on(payload))
    assert len(commands) == 1, commands
    done = subprocess.run(
        commands[0].split(" "),
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )
    assert (done.returncode, done.stderr) == (0, ""), done.stderr
    return cast("JsonObject", json.loads(done.stdout))


def matched_on(payload: JsonObject) -> str:
    """What an event's matcher reads (Claude's hooks docs): a tool call's tool,
    a subagent start's type, a typed skill's name."""
    match payload["hook_event_name"]:
        case "SubagentStart":
            return cast("str", payload["agent_type"])
        case "UserPromptExpansion":
            return cast("str", payload["command_name"])
        case _:
            return cast("str", payload["tool_name"])


def hook_commands(flavor: str, event: str, tool: str) -> list[str]:
    """The commands Claude runs for an event matched on `tool`: those whose
    matcher, a regular expression, matches it, or that have none."""
    settings = cast("JsonObject", json.loads(Path(SETTINGS[flavor]).read_text()))
    entries = cast("dict[str, list[JsonObject]]", settings["hooks"])[event]
    return [
        cast("str", hook["command"])
        for entry in entries
        if re.fullmatch(cast("str", entry.get("matcher") or ".*"), tool)
        for hook in cast("list[JsonObject]", entry["hooks"])
    ]


def denied(flavor: str, payload: JsonObject) -> str:
    output = answer(flavor, "PreToolUse", payload)
    specific = cast("JsonObject", output["hookSpecificOutput"])
    assert specific["permissionDecision"] == "deny"
    return cast("str", specific["permissionDecisionReason"])


def additional_context(output: JsonObject) -> str:
    specific = cast("JsonObject", output["hookSpecificOutput"])
    return cast("str", specific["additionalContext"])


def shell_call(
    root: Path, command: str, agent: str | None = None, role: str = "implementer"
) -> JsonObject:
    """A PreToolUse payload of a Bash call, with the keys the snapshot holds."""
    payload: JsonObject = {
        "session_id": "abc123",
        "transcript_path": str(lead_transcript(root)),
        "cwd": str(root),
        "permission_mode": "auto",
        "effort": "high",
        "prompt_id": "p1",
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command, "description": "run it"},
        "tool_use_id": "toolu_now",
    }
    if agent is not None:
        payload |= {"agent_id": agent, "agent_type": role}
    return snapshot_shaped(payload)


def shell_ran(
    root: Path, command: str, stdout: str, agent: str | None, role: str
) -> JsonObject:
    """The PostToolUse payload of that Bash call, once it printed `stdout`."""
    ran: JsonObject = {
        "hook_event_name": "PostToolUse",
        "tool_response": {"stdout": stdout, "stderr": "", "interrupted": False},
        "duration_ms": 120,
    }
    return snapshot_shaped(shell_call(root, command, agent, role) | ran)


def bound_engineer(flavor: str, tmp_path: Path) -> tuple[Path, Path]:
    """An engineer whose hooks fire in a foreign worktree, bound by its `state
    init` to its own: the two worktrees, its own first."""
    own, foreign = worktree(tmp_path / "own"), worktree(tmp_path / "foreign")
    ran_init = shell_ran(
        foreign,
        f"cd {own} && state init --notes {tmp_path}/notes/ --task t2",
        f"run 0a1b2c3d {tmp_path}/notes {own}\n",
        agent=WORKER,
        role="engineer",
    )
    _ = answer(flavor, "PostToolUse", ran_init)
    return own, foreign


def mcp_result(root: Path) -> JsonObject:
    """A PostToolUse payload of the lead's MCP call."""
    result: JsonObject = {
        "hook_event_name": "PostToolUse",
        "tool_name": "mcp__github__get_pull_request",
        "tool_input": {"pullNumber": 7},
        "tool_response": [{"type": "text", "text": "{}"}],
        "duration_ms": 120,
    }
    return snapshot_shaped(shell_call(root, "") | result)


def snapshot_shaped(payload: JsonObject) -> JsonObject:
    """`payload`, once its keys are those the snapshot recorded for its event
    and speaker: a payload Claude does not send would prove nothing."""
    recorded = [
        set(cast("list[str]", event["keys"]))
        for event in cast("list[JsonObject]", SNAPSHOT["events"])
        if event["event"] == payload["hook_event_name"]
    ]
    assert set(payload) in recorded, sorted(payload)
    return payload


def worktree(path: Path) -> Path:
    """A fresh git worktree at `path`, as git names its top."""
    _ = subprocess.run(["git", "init", "-q", str(path)], check=True)
    return path.resolve()


# ---- The transcript, in Claude's layout ---------------------------------------------


def lead_transcript(root: Path) -> Path:
    return root / "abc123.jsonl"


def worker_transcript(root: Path) -> Path:
    return root / "abc123" / "subagents" / f"agent-{WORKER}.jsonl"
