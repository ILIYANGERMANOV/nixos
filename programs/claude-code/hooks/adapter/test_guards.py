"""The guards end to end, as each flavor deploys them: Claude's hook JSON, shaped
as the contract snapshot recorded it, through the hook commands its settings.json
holds, against a transcript on disk."""

import json
import os
import re
import subprocess
from pathlib import Path
from typing import cast

import pytest
from agent_hook import JsonObject
from transcript_fixtures import bash, model_call, write_transcript

# Flavor name -> its settings.json, as installed.
SETTINGS = cast("dict[str, str]", json.loads(os.environ["CLAUDE_SETTINGS"]))
SNAPSHOT = cast(
    "JsonObject",
    json.loads((Path(__file__).parents[1] / "contract" / "snapshot.json").read_text()),
)

# The synthetic secret file every test build gives the base profile.
QA_KEY_FILE = "/run/secrets/qa-sepolia-key"
WORKER = "a1b2"

flavors = pytest.mark.parametrize("flavor", sorted(SETTINGS))


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

    assert "grep -n first" in told


@flavors
def test_a_call_two_guards_deny_tells_both_hints(flavor: str, tmp_path: Path) -> None:
    _ = (tmp_path / "huge").write_bytes(bytes(20_000))

    told = denied(flavor, shell_call(tmp_path, "cat huge; sleep 60"))

    assert "grep -n first" in told
    assert "run_in_background" in told


@flavors
def test_a_secret_path_is_denied(flavor: str, tmp_path: Path) -> None:
    told = denied(flavor, shell_call(tmp_path, f"cat {QA_KEY_FILE}"))

    assert "Never read it from a shell" in told


@flavors
def test_a_subagents_second_ci_read_is_denied(flavor: str, tmp_path: Path) -> None:
    write_transcript(
        worker_transcript(tmp_path),
        model_call("m1", 1_000, bash("toolu_m1", "gh pr checks 7")),
    )

    told = denied(flavor, shell_call(tmp_path, "gh pr checks 7", agent=WORKER))

    assert "never waits on CI" in told


@flavors
def test_the_leads_second_ci_read_is_allowed(flavor: str, tmp_path: Path) -> None:
    write_transcript(
        lead_transcript(tmp_path),
        model_call("m1", 1_000, bash("toolu_m1", "gh pr checks 7")),
    )

    assert answer(flavor, "PreToolUse", shell_call(tmp_path, "gh pr checks 7")) == {}


@flavors
def test_crossing_150k_after_an_mcp_tool_gives_the_notice(
    flavor: str, tmp_path: Path
) -> None:
    write_transcript(
        lead_transcript(tmp_path),
        [
            *model_call("m1", 148_000, bash("toolu_m1", "ls")),
            *model_call("m2", 150_500, bash("toolu_m2", "ls")),
        ],
    )

    output = answer(flavor, "PostToolUse", mcp_result(tmp_path))

    assert "Context 150k" in additional_context(output)


@flavors
def test_a_subagent_claude_names_no_id_still_runs_the_guards(
    flavor: str, tmp_path: Path
) -> None:
    unnamed = shell_call(tmp_path, f"cat {QA_KEY_FILE}", agent=WORKER) | {
        "agent_id": None
    }

    assert "Never read it from a shell" in denied(flavor, unnamed)


# ---- Claude's side ------------------------------------------------------------------


def answer(flavor: str, event: str, payload: JsonObject) -> JsonObject:
    """What Claude reads back from the flavor's hooks for `payload`."""
    commands = hook_commands(flavor, event, cast("str", payload["tool_name"]))
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


def hook_commands(flavor: str, event: str, tool: str) -> list[str]:
    """The commands Claude runs for a call of `tool`: those whose matcher, a
    regular expression, matches it, or that have none."""
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


def shell_call(root: Path, command: str, agent: str | None = None) -> JsonObject:
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
        payload |= {"agent_id": agent, "agent_type": "implementer"}
    return snapshot_shaped(payload)


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


# ---- The transcript, in Claude's layout ---------------------------------------------


def lead_transcript(root: Path) -> Path:
    return root / "abc123.jsonl"


def worker_transcript(root: Path) -> Path:
    return root / "abc123" / "subagents" / f"agent-{WORKER}.jsonl"
