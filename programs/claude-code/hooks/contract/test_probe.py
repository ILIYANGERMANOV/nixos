"""The probe's compare: a healthy run's record is free of ids, paths and timings,
and a client that breaks the contract shows in the diff. The run itself needs
the real `claude`: `just probe-agents-hooks`."""

from enum import Enum, auto
from pathlib import Path

from hypothesis import given
from hypothesis import strategies as st
from model import HANDBACK_TAG, ORIGINAL_COMMAND, REWRITE_TAG, SPAWN_TAG, Json
from probe import Logs, diff, record, rewrite

LEAD_TOOLS: list[Json] = ["Agent", "Bash", "Read", "Write"]
REPO = Path("/probe/repo")


class Breakage(Enum):
    """The ways a newer client could break the contract the hooks rely on."""

    RENAMED_HANDBACK = auto()
    UNTAGGED_SUBAGENT = auto()
    IGNORED_UPDATED_INPUT = auto()


def healthy_run(
    repo: Path = REPO,
    session: str = "session-1",
    agent_id: str = "agent-1",
    duration: int = 5,
    breaks: Breakage | None = None,
) -> Logs:
    """What Claude Code 2.1.314 sends for the probe's script, cut to one call
    of each kind, or broken the way `breaks` says."""
    sub = str(repo / "sub")
    honours_updated_input = breaks is not Breakage.IGNORED_UPDATED_INPUT
    handback_tool = (
        "ReportBack" if breaks is Breakage.RENAMED_HANDBACK else "SubagentHandback"
    )
    ran = f"echo {REWRITE_TAG}" if honours_updated_input else ORIGINAL_COMMAND
    subagent: dict[str, Json] = (
        {}
        if breaks is Breakage.UNTAGGED_SUBAGENT
        else {"agent_id": agent_id, "agent_type": "probe"}
    )

    def call(
        event: str,
        tool: str,
        tool_input: Json,
        cwd: str,
        response: Json = None,
        **extra: Json,
    ) -> dict[str, Json]:
        post: dict[str, Json] = (
            {"tool_response": response, "duration_ms": duration}
            if event == "PostToolUse"
            else {}
        )
        return {
            "hook_event_name": event,
            "session_id": session,
            "transcript_path": f"{repo}/{session}.jsonl",
            "cwd": cwd,
            "pwd": cwd,
            "tool_name": tool,
            "tool_input": tool_input,
            "tool_use_id": f"toolu-{session}",
            **post,
            **extra,
        }

    def start(source: str) -> dict[str, Json]:
        return {
            "hook_event_name": "SessionStart",
            "session_id": session,
            "cwd": str(repo),
            "pwd": str(repo),
            "source": source,
        }

    hooks = [
        start("startup"),
        call("PreToolUse", "Bash", {"command": ORIGINAL_COMMAND}, str(repo)),
        call(
            "PostToolUse",
            "Bash",
            {"command": ran},
            str(repo),
            {"stdout": ran.removeprefix("echo "), "stderr": ""},
        ),
        call(
            "PostToolUse",
            "Bash",
            {"command": "cd sub"},
            sub,
            {"stdout": "", "stderr": ""},
        ),
        call(
            "PostToolUse",
            "Bash",
            {"command": "pwd"},
            sub,
            {"stdout": sub, "stderr": ""},
            **subagent,
        ),
        call(
            "PreToolUse", handback_tool, {"message": "PROBE-HANDBACK"}, sub, **subagent
        ),
        call(
            "PostToolUse",
            "Agent",
            {"prompt": f"Run the probe. {SPAWN_TAG}"},
            sub,
            {"agentId": agent_id, "totalDurationMs": duration},
        ),
        start("resume"),
        start("compact"),
    ]
    requests: list[dict[str, Json]] = [
        {"speaker": "lead", "tools": LEAD_TOOLS, "witnesses": []},
        {
            "speaker": "lead",
            "tools": LEAD_TOOLS,
            "witnesses": [REWRITE_TAG] if honours_updated_input else [],
        },
        {"speaker": "classifier", "tools": [], "witnesses": []},
        {
            "speaker": "subagent",
            "tools": ["Bash", handback_tool],
            "witnesses": [SPAWN_TAG],
        },
        {"speaker": "lead", "tools": LEAD_TOOLS, "witnesses": [HANDBACK_TAG]},
    ]
    return Logs(repo, hooks, requests)


names = st.text(alphabet="abcdef0123456789-", min_size=1, max_size=12)


@given(names, names, names, st.integers(min_value=0, max_value=10**6))
def test_two_healthy_runs_give_the_same_record(
    repo: str, session: str, agent_id: str, duration: int
) -> None:
    assert (
        diff(
            record(healthy_run()),
            record(
                healthy_run(Path("/probe") / repo / "repo", session, agent_id, duration)
            ),
        )
        == []
    )


def test_a_renamed_handback_tool_fails_the_compare() -> None:
    removed, added = changed(healthy_run(breaks=Breakage.RENAMED_HANDBACK))

    assert '"SubagentHandback"' in removed
    assert '"ReportBack"' in added


def test_a_subagent_without_its_agent_id_fails_the_compare() -> None:
    removed, _ = changed(healthy_run(breaks=Breakage.UNTAGGED_SUBAGENT))

    assert '"agent_id"' in removed


def test_an_ignored_updated_input_fails_the_compare() -> None:
    removed, _ = changed(healthy_run(breaks=Breakage.IGNORED_UPDATED_INPUT))

    assert f'"command": "echo {REWRITE_TAG}"' in removed
    assert f'"{REWRITE_TAG}"' in removed


def test_a_subagent_cwd_is_relative_to_the_repo() -> None:
    events = as_list(as_dict(record(healthy_run()))["events"])

    assert as_dict(events[4])["cwd"] == "sub"
    assert as_dict(events[4])["stdout"] == "<repo>/sub"


def test_the_hook_rewrites_the_probed_bash_command_keeping_its_other_fields() -> None:
    payload: dict[str, Json] = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": ORIGINAL_COMMAND, "description": "say it"},
    }

    assert rewrite(payload) == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {"command": f"echo {REWRITE_TAG}", "description": "say it"},
        }
    }


def test_the_hook_tags_the_spawn_prompt_and_the_handback_message() -> None:
    spawn: dict[str, Json] = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Agent",
        "tool_input": {"prompt": "go"},
    }
    handback: dict[str, Json] = {
        "hook_event_name": "PreToolUse",
        "tool_name": "SubagentHandback",
        "tool_input": {"message": "done"},
    }

    assert updated(rewrite(spawn)) == {"prompt": f"go {SPAWN_TAG}"}
    assert updated(rewrite(handback)) == {"message": f"done {HANDBACK_TAG}"}


def test_the_hook_leaves_any_other_call_alone() -> None:
    other: dict[str, Json] = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "pwd"},
    }
    after: dict[str, Json] = {
        "hook_event_name": "PostToolUse",
        "tool_name": "Agent",
        "tool_input": {"prompt": "go"},
    }

    assert rewrite(other) == {}
    assert rewrite(after) == {}


def changed(run: Logs) -> tuple[set[str], set[str]]:
    """The lines the diff against a healthy run removes and adds, unindented."""
    lines = diff(record(healthy_run()), record(run))[2:]
    removed = {line[1:].strip().rstrip(",") for line in lines if line.startswith("-")}
    added = {line[1:].strip().rstrip(",") for line in lines if line.startswith("+")}
    return removed, added


def updated(output: Json) -> Json:
    return as_dict(as_dict(output)["hookSpecificOutput"])["updatedInput"]


def as_dict(value: Json) -> dict[str, Json]:
    assert isinstance(value, dict)
    return value


def as_list(value: Json) -> list[Json]:
    assert isinstance(value, list)
    return value
