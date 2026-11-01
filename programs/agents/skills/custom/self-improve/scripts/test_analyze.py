"""Black-box tests for the self-improve analyzer, run by `python-tests`.

Each test writes synthetic transcripts in Claude Code's on-disk layout, runs
the analyzer's CLI on them and asserts on the report it prints. Synthetic on
purpose: this repository is public and real transcripts are private.

The last section is the exception, differential rather than black-box: real shfmt
through `bash_commands.parse` supplies the words of each simple command and the
analyzer's own `step` classifies them, so what differs is how the command was read
and nothing else. It compares `label` and `check_key`, never the steps.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from functools import partial
from pathlib import Path
from typing import ClassVar

import analyze
import pytest
from bash_commands import Parsed, Unparsable, parse
from bash_corpus import PARSED

# What a transcript line can hold, spelled out so the builders stay checked.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
type JsonObject = dict[str, Json]

ANALYZER = Path(__file__).with_name("analyze.py")
# Bare python, so an import outside the stdlib fails here as it would when deployed.
PYTHON = os.environ["STDLIB_PYTHON"]
BASE = datetime(2026, 1, 1, tzinfo=UTC)


def at(seconds: float) -> str:
    return (BASE + timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True, slots=True)
class Outcome:
    """How a tool call ended, as its result line records it."""

    content: Json = "ok"
    error: bool = False
    background: bool = False


OK = Outcome()


@dataclass
class Transcript:
    """Builds one agent's JSONL transcript; times are seconds after BASE."""

    cwd: str = "/home/dev/repos/demo"
    # A subagent's spawning Agent call, as its meta.json names it.
    parent: str | None = None
    # The subagent that spawned this one, as its meta.json names it.
    parent_agent: str | None = None
    lines: list[JsonObject] = field(default_factory=list)
    calls: int = 0

    def event(self, t: float, kind: str, **fields: Json) -> Transcript:
        self.lines.append({"type": kind, "timestamp": at(t), "cwd": self.cwd, **fields})
        return self

    def human(self, t: float, text: str) -> Transcript:
        return self.event(
            t,
            "user",
            origin={"kind": "human"},
            message={"role": "user", "content": text},
        )

    def command(self, t: float, name: str) -> Transcript:
        return self.human(
            t,
            f"<command-message>{name}</command-message>\n<command-name>/{name}</command-name>",
        )

    def brief(self, t: float, text: str) -> Transcript:
        """A subagent's prompt: its first user line, typed by no person."""
        return self.event(t, "user", message={"role": "user", "content": text})

    def handback(self, t: float, message: str) -> Transcript:
        _ = self.tool(t, "SubagentHandback", t, message=message)
        return self

    def reply(
        self,
        t: float,
        usage: JsonObject | None = None,
        skill: str | None = None,
        content_lines: int = 1,
        text: str = "ok",
    ) -> Transcript:
        """One model response, written as Claude Code does: one line per content block."""
        self.calls += 1
        message: JsonObject = {
            "id": f"msg_{self.calls}",
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "usage": usage or {},
        }
        for _ in range(content_lines):
            _ = self.event(t, "assistant", message=message, attributionSkill=skill)
        return self

    def tool(
        self,
        t: float,
        name: str,
        done: float,
        *,
        outcome: Outcome = OK,
        **tool_input: Json,
    ) -> str:
        """A tool call and its result. Returns the tool_use id."""
        self.calls += 1
        use_id = f"toolu_{self.calls}"
        self.tool_use(t, f"msg_{self.calls}", use_id, name, tool_input)
        extra: JsonObject = (
            {"backgroundTaskId": f"bg{self.calls}"} if outcome.background else {}
        )
        self.tool_result(done, use_id, outcome, extra)
        return use_id

    def tool_use(
        self, t: float, response: str, use_id: str, name: str, tool_input: JsonObject
    ) -> None:
        _ = self.event(
            t,
            "assistant",
            message={
                "id": response,
                "role": "assistant",
                "usage": {},
                "content": [
                    {
                        "type": "tool_use",
                        "id": use_id,
                        "name": name,
                        "input": tool_input,
                    }
                ],
            },
        )

    def tool_result(
        self,
        t: float,
        use_id: str,
        outcome: Outcome = OK,
        extra: JsonObject | None = None,
    ) -> None:
        _ = self.event(
            t,
            "user",
            toolUseResult=extra or {},
            message={
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": use_id,
                        "content": outcome.content,
                        "is_error": outcome.error,
                    }
                ],
            },
        )

    def bash(
        self, t: float, command: str, done: float, *, outcome: Outcome = OK
    ) -> str:
        return self.tool(t, "Bash", done, outcome=outcome, command=command)

    def siblings(self, *calls: tuple[float, str, JsonObject, float]) -> None:
        """One response of several (streamed at, tool, input, done) calls, written as Claude Code does:
        one line per block, stamped when that block finished streaming, and each result where it landed,
        so a tool finishing mid-stream answers between the lines of its own response."""
        self.calls += 1
        response = f"msg_{self.calls}"
        lines: list[tuple[float, partial[None]]] = []
        for t, name, tool_input, done in calls:
            self.calls += 1
            use_id = f"toolu_{self.calls}"
            lines.append(
                (t, partial(self.tool_use, t, response, use_id, name, tool_input))
            )
            lines.append((done, partial(self.tool_result, done, use_id)))
        for _, write in sorted(lines, key=lambda line: line[0]):
            write()

    def notify(self, t: float, use_id: str, status: str, summary: str) -> Transcript:
        return self.event(
            t,
            "queue-operation",
            operation="enqueue",
            content=notification(use_id, status, summary),
        )

    def startup(self, t: float, instructions: int, listing: int) -> Transcript:
        """The attachments an agent gets before its first call, with `instructions` and `listing` chars."""
        files: list[Json] = [
            {
                "path": "/home/dev/CLAUDE.md",
                "type": "User",
                "content": "x" * instructions,
            }
        ]
        _ = self.event(
            t, "attachment", attachment={"type": "instructions", "files": files}
        )
        return self.event(
            t,
            "attachment",
            attachment={
                "type": "skill_listing",
                "content": "y" * listing,
                "skillCount": 1,
            },
        )

    def attach_notification(
        self, t: float, use_id: str, status: str, summary: str
    ) -> Transcript:
        """How a subagent's transcript carries a task notification."""
        attachment: JsonObject = {
            "type": "queued_command",
            "commandMode": "task-notification",
            "prompt": notification(use_id, status, summary),
        }
        return self.event(t, "attachment", attachment=attachment)


def notification(use_id: str, status: str, summary: str) -> str:
    return (
        f"<task-notification>\n<task-id>x</task-id>\n<tool-use-id>{use_id}</tool-use-id>\n"
        f"<status>{status}</status>\n<summary>{summary}</summary>\n</task-notification>"
    )


@dataclass
class Home:
    """A fake ~/.claude/projects holding sessions, each with optional subagents."""

    root: Path

    def session(
        self,
        sid: str,
        main: Transcript,
        subagents: dict[str, tuple[str, str, Transcript]] | None = None,
    ) -> None:
        project = self.root / ("-" + main.cwd.strip("/").replace("/", "-"))
        write(project / f"{sid}.jsonl", main)
        for agent_id, (kind, description, transcript) in (subagents or {}).items():
            base = project / sid / "subagents" / f"agent-{agent_id}"
            write(base.with_suffix(".jsonl"), transcript)
            meta = {
                "agentType": kind,
                "description": description,
                "toolUseId": transcript.parent,
                "parentAgentId": transcript.parent_agent,
            }
            _ = base.with_suffix(".meta.json").write_text(json.dumps(meta))

    def report(self, *args: str) -> str:
        run = subprocess.run(
            [PYTHON, "-I", str(ANALYZER), "--root", str(self.root), *args],
            capture_output=True,
            text=True,
            check=True,
        )
        return run.stdout


def worker(description: str, transcript: Transcript) -> tuple[str, str, Transcript]:
    return "general-purpose", description, transcript


def write(path: Path, transcript: Transcript) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text("".join(json.dumps(line) + "\n" for line in transcript.lines))


def section(report: str, title: str) -> str:
    """The body of the report section titled `title`."""
    return report.split(f"## {title}", 1)[-1].split("\n## ", 1)[0]


def row(report: str, title: str, first_cell: str) -> list[str]:
    """The cells of the row whose first cell is `first_cell`, in the section titled `title`."""
    for line in section(report, title).splitlines():
        cells = [c.strip() for c in line.strip("|").split("|")]
        if line.startswith("|") and cells[0] == first_cell:
            return cells
    raise AssertionError(f"no row starting with {first_cell!r} in:\n{report}")


@pytest.fixture
def home(tmp_path: Path) -> Home:
    return Home(tmp_path)


class TestTokens:
    def test_a_response_split_over_content_lines_is_counted_once(
        self, home: Home
    ) -> None:
        # Given: one response written as three lines, and a second response
        main = Transcript().human(0, "go")
        _ = main.reply(
            1,
            {
                "input_tokens": 10,
                "cache_read_input_tokens": 2000,
                "cache_creation_input_tokens": 300,
                "output_tokens": 40,
            },
            content_lines=3,
        )
        _ = main.reply(
            2, {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 0}
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then: tokens are the sum of two responses, not four lines
        assert "main 15/3k/300/40" in report
        assert row(report, "Tokens by agent type", "main")[1:4] == [
            "1",
            "2",
            "15/3k/300/40",
        ]

    def test_subagent_tokens_are_reported_by_type_and_description(
        self, home: Home
    ) -> None:
        # Given: a session with one implementer subagent
        main = (
            Transcript()
            .command(0, "engineer")
            .reply(1, {"cache_read_input_tokens": 1000})
        )
        sub = Transcript().reply(
            5,
            {
                "cache_read_input_tokens": 2_000_000,
                "cache_creation_input_tokens": 50_000,
            },
        )
        _ = sub.reply(6, {"cache_read_input_tokens": 3_000_000}, skill="engineering")
        home.session("s1", main, {"a1": worker("Implement parser", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Tokens by agent type", "general-purpose")[1:5] == [
            "1",
            "2",
            "0/5.0M/50k/0",
            "3.0M",
        ]
        assert row(report, "Costliest subagents", "s1")[1:5] == [
            "general-purpose",
            "Implement parser",
            "0/5.0M/50k/0",
            "3.0M",
        ]
        assert row(report, "Tokens by skill", "engineering")[1:] == ["1", "0/3.0M/0/0"]
        assert "/engineer" in row(report, "Sessions", "s1")[5]


class TestEffectiveCost:
    USAGE: ClassVar[JsonObject] = {
        "input_tokens": 10,
        "cache_read_input_tokens": 1000,
        "cache_creation_input_tokens": 400,
        "output_tokens": 20,
    }  # 10 + 100 + 500 + 100 = 710

    def test_a_call_is_weighed_by_what_it_pays(self, home: Home) -> None:
        # Given: a main call and a subagent call of the same usage, the subagent's reported twice
        main = Transcript().human(0, "go").reply(1, self.USAGE)
        sub = (
            Transcript()
            .brief(5, "build")
            .reply(6, self.USAGE, content_lines=2)
            .reply(7, self.USAGE)
        )
        home.session("s1", main, {"a1": worker("Implement parser", sub)})
        # When
        report = home.report()
        # Then: every view sums weighted calls, counting a split response once
        assert "2k = main 710, subagents 1k" in section(report, "Session report")
        assert row(report, "Sessions", "s1")[-1] == "2k"
        assert row(report, "Tokens by agent type", "main")[-1] == "710"
        assert row(report, "Tokens by agent type", "general-purpose")[-1] == "1k"
        assert row(report, "Costliest subagents", "s1")[-1] == "1k"
        assert row(report, "Loop steps", "implement")[-1] == "1k"

    def test_output_outranks_cached_context(self, home: Home) -> None:
        # Given: a large cached subagent and a small one that writes more
        cached = (
            Transcript().brief(5, "a").reply(6, {"cache_read_input_tokens": 100_000})
        )
        verbose = Transcript().brief(5, "b").reply(6, {"output_tokens": 10_000})
        home.session(
            "s1",
            idle_main(),
            {"a1": worker("Cached", cached), "a2": worker("Verbose", verbose)},
        )
        # When
        lines = section(home.report(), "Costliest subagents").splitlines()
        # Then
        assert "Verbose" in next(line for line in lines if "general-purpose" in line)


REWRITE: JsonObject = {
    "input_tokens": 1000,
    "cache_read_input_tokens": 9000,
    "cache_creation_input_tokens": 90_000,
}  # costs 112k


class TestCacheRewrites:
    def test_a_subagent_rewrite_after_each_wait_is_split_by_that_wait(
        self, home: Home
    ) -> None:
        # Given: a subagent that loses its cache behind a foreground Bash, a foreground Agent and no tool
        sub = Transcript().brief(0, "build").reply(1, {"cache_read_input_tokens": 1000})
        _ = sub.bash(2, "just test", 400)
        _ = sub.reply(401, REWRITE)
        _ = sub.tool(402, "Agent", 800, description="Research")
        _ = sub.reply(801, REWRITE)
        _ = sub.reply(1200, REWRITE)
        home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Cache rewrites", "foreground Bash")[1:] == ["1", "112k"]
        assert row(report, "Cache rewrites", "Agent")[1:] == ["1", "112k"]
        assert row(report, "Cache rewrites", "idle")[1:] == ["1", "112k"]
        assert "3 rewrites, 338k effective" in section(report, "Cache rewrites")
        assert row(report, "Cache rewrites", "s1")[1:] == [
            "general-purpose",
            "Implement parser",
            "3",
            "338k",
        ]

    def test_a_gap_within_the_cache_life_is_no_rewrite(self, home: Home) -> None:
        # Given: a large write under 5 minutes after the previous call
        sub = Transcript().brief(0, "build").reply(1).reply(299, REWRITE)
        home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        assert "0 rewrites" in section(home.report(), "Cache rewrites")

    def test_a_small_write_after_a_gap_is_no_rewrite(self, home: Home) -> None:
        # Given: half the context written after a long gap, the cache having survived the rest
        half: JsonObject = {
            "cache_read_input_tokens": 50_000,
            "cache_creation_input_tokens": 50_000,
        }
        sub = Transcript().brief(0, "build").reply(1).reply(1000, half)
        home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        assert "0 rewrites" in section(home.report(), "Cache rewrites")

    def test_a_main_agent_keeps_its_cache_for_an_hour(self, home: Home) -> None:
        # Given: main gaps of 59 and 61 minutes before a large write
        main = (
            Transcript()
            .human(0, "go")
            .reply(1)
            .reply(3541, REWRITE)
            .reply(7202, REWRITE)
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then: only the second counts
        assert row(report, "Cache rewrites", "s1")[1:] == ["main", "", "1", "112k"]
        assert row(report, "Cache rewrites", "idle")[1:] == ["1", "112k"]

    def test_a_background_bash_is_idle(self, home: Home) -> None:
        # Given: the wait came after a command sent to the background
        sub = Transcript().brief(0, "build")
        _ = sub.bash(1, "just test", 2, outcome=Outcome(background=True))
        _ = sub.reply(400, REWRITE)
        home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        assert row(home.report(), "Cache rewrites", "idle")[1:] == ["1", "112k"]


class TestWallTime:
    def test_foreground_and_background_calls_are_timed_to_their_result_and_notification(
        self, home: Home
    ) -> None:
        # Given: a 90s foreground check and a background one finishing 300s after launch
        main = Transcript().human(0, "go")
        _ = main.bash(10, "cd /repo && just check", 100)
        bg = main.bash(
            200,
            "just check 2>&1 | tail",
            201,
            outcome=Outcome("Command running in background", background=True),
        )
        _ = main.notify(
            500, bg, "completed", 'Background command "check" completed (exit code 0)'
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per Bash command", "just check")[1:6] == [
            "1",
            "2m",
            "1",
            "5m",
            "300s",
        ]

    def test_sibling_calls_are_timed_from_the_end_of_their_response(
        self, home: Home
    ) -> None:
        # Given: a quick mkdir streamed before a Write whose block took 60s to stream
        main = Transcript().human(0, "go")
        main.siblings(
            (40, "Bash", {"command": "mkdir -p /work/x"}, 102),
            (100, "Write", {"file_path": "/work/x/a"}, 102),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then: neither call is charged the 60s of streaming
        assert row(report, "Wall time per Bash command", "mkdir")[5] == "2s"
        assert row(report, "Wall time per tool", "Write")[5] == "2s"

    def test_a_call_finishing_mid_stream_is_timed_from_its_own_line(
        self, home: Home
    ) -> None:
        # Given: a Read answered at 45 while its response streamed on until 100
        main = Transcript().human(0, "go")
        main.siblings(
            (40, "Read", {"file_path": "/a"}, 45),
            (100, "Write", {"file_path": "/b"}, 102),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then: the Read keeps its 5s and is not moved past its own result
        assert row(report, "Wall time per tool", "Read")[5] == "5s"
        assert row(report, "Wall time per tool", "Write")[5] == "2s"

    def test_a_subagent_background_start_is_timed_to_its_notification(
        self, home: Home
    ) -> None:
        # Given: a subagent whose transcript has only the result text and an attached notification
        start = "Command running in background with ID: b1. Output is being written to: /tmp/b1.output"
        sub = awaited_subagent()
        bg = sub.bash(10, "just check", 11, outcome=Outcome(start))
        _ = sub.attach_notification(
            310, bg, "completed", 'Background command "check" completed (exit code 0)'
        )
        home.session("s1", awaiting_subagent(400), {"s": worker("Implement", sub)})
        # When
        report = home.report()
        # Then: one background call of 300s, not a 1s foreground one
        assert row(report, "Wall time per Bash command", "just check")[1:6] == [
            "0",
            "0m",
            "1",
            "5m",
            "300s",
        ]

    def test_a_subagent_timeout_moved_to_the_background_is_timed_to_its_notification(
        self, home: Home
    ) -> None:
        # Given: a foreground call the harness moved to the background at its timeout
        moved = "Command did not complete within its 600s timeout and was moved to the background with ID: b1."
        sub = awaited_subagent()
        bg = sub.bash(10, "just check", 610, outcome=Outcome(moved))
        _ = sub.attach_notification(
            910, bg, "completed", 'Background command "check" completed (exit code 0)'
        )
        home.session("s1", awaiting_subagent(1000), {"s": worker("Implement", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per Bash command", "just check")[1:6] == [
            "0",
            "0m",
            "1",
            "15m",
            "900s",
        ]

    def test_a_subagent_background_agent_is_timed_to_its_notification(
        self, home: Home
    ) -> None:
        # Given: a subagent spawning a background agent, with the result as a text block
        launched: Json = [
            {"type": "text", "text": "Async agent launched successfully."}
        ]
        sub = awaited_subagent()
        child = sub.tool(
            10, "Agent", 11, outcome=Outcome(launched), description="Research"
        )
        _ = sub.attach_notification(130, child, "completed", "Agent finished")
        home.session("s1", awaiting_subagent(50), {"s": worker("Implement", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per tool", "Agent")[1:3] == ["bg", "1"]
        assert row(report, "Wall time per tool", "Agent")[4:] == ["120s", "120s"]

    def test_a_subagent_background_failure_is_a_failure(self, home: Home) -> None:
        # Given: a background command failing in a subagent's attached notification
        sub = awaited_subagent()
        bg = sub.bash(
            10,
            "just check",
            11,
            outcome=Outcome("Command running in background with ID: b1."),
        )
        _ = sub.attach_notification(
            100, bg, "failed", 'Background command "check" failed with exit code 2'
        )
        home.session("s1", awaiting_subagent(200), {"s": worker("Implement", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per Bash command", "just check")[6] == "1"

    def test_output_quoting_a_background_start_stays_a_foreground_call(
        self, home: Home
    ) -> None:
        # Given: a foreground command that prints the words mid-output
        main = Transcript().human(0, "go")
        _ = main.bash(
            10,
            "just check",
            20,
            outcome=Outcome("note: Command running in background with ID: b1."),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per Bash command", "just check")[1:3] == [
            "1",
            "0m",
        ]

    def test_waiting_on_the_person_is_split_from_work(self, home: Home) -> None:
        # Given: a 10 min gap before the person's second prompt and a 2 min question
        main = Transcript().human(0, "go").reply(60)
        _ = main.human(660, "next")
        _ = main.tool(700, "AskUserQuestion", 820)
        _ = main.reply(3600)
        home.session("s1", main)
        # When
        report = home.report()
        # Then: 12 of the 60 minutes are waiting
        assert "Wall clock: 1.0h = work 0.8h + waiting on the person 0.2h" in report
        assert row(report, "Sessions", "s1")[3:5] == ["60m", "12m"]
        # And: the question is not ranked as a tool bottleneck
        assert "| AskUserQuestion |" not in section(report, "Wall time per tool")

    def test_a_human_gap_with_background_work_running_is_work(self, home: Home) -> None:
        # Given: a background agent works 20 min into a 30 min silence in the main transcript,
        # and its notification is not in it, so only the subagent's own calls show the work
        main = Transcript().human(0, "go")
        spawn = main.tool(
            60, "Agent", 61, outcome=Outcome(background=True), description="Review"
        )
        _ = main.human(1860, "next").reply(3600)
        sub = Transcript(parent=spawn)
        _ = sub.bash(61, "just check", 1260)
        home.session("s1", main, {"a1": worker("Review", sub)})
        # When
        report = home.report()
        # Then: only the 10 idle minutes after the subagent's work are waiting
        assert row(report, "Sessions", "s1")[3:5] == ["60m", "10m"]


class TestRedundantChecks:
    def test_reruns_are_flagged_only_when_nothing_but_docs_changed(
        self, home: Home
    ) -> None:
        # Given: a rerun with no edit, one after a doc edit, one after a code edit
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check 2> /tmp/err.log", 70)
        _ = main.bash(80, "cd /repo && just check > /tmp/a.log", 140)
        _ = main.tool(150, "Edit", 151, file_path="/repo/README.md")
        _ = main.bash(160, "just check", 220)
        _ = main.tool(230, "Edit", 231, file_path="/repo/src/Main.hs")
        _ = main.bash(240, "just check", 300)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 2, 2m." in report
        assert "| just check | no edit |" in report
        assert "| just check | doc-only edit |" in report

    def test_an_edit_by_another_agent_of_the_session_counts_as_a_change(
        self, home: Home
    ) -> None:
        # Given: the orchestrator checks, its implementer edits, the orchestrator checks again
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check", 70)
        _ = main.bash(200, "just check", 260)
        sub = Transcript()
        _ = sub.tool(100, "Write", 101, file_path="/repo/src/New.hs")
        home.session("s1", main, {"a1": worker("Implement", sub)})
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 0, 0m." in report

    def test_steps_run_in_front_of_a_full_check_are_chains(self, home: Home) -> None:
        # Given: build && check in one call, and a test run right before a check
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just build && just check", 100)
        _ = main.tool(110, "Edit", 111, file_path="/repo/src/Main.hs")
        _ = main.bash(120, "nix run .#test -- -m parser", 180)
        _ = main.bash(190, "just check", 250)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert (
            "Build/test steps run before a full check with no edit between: 2, 1m."
            in report
        )
        assert "| nix run .#test -- -m parser | 60s |" in report

    def test_an_edit_sent_before_a_check_in_one_response_is_a_change(
        self, home: Home
    ) -> None:
        # Given: an Edit and a rerun of a check, sibling calls of one response
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check", 70)
        main.siblings(
            (80, "Edit", {"file_path": "/repo/src/Main.hs"}, 91),
            (90, "Bash", {"command": "just check"}, 150),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 0, 0m." in report

    def test_an_edit_sent_after_a_check_in_one_response_is_a_change_for_the_next_run(
        self, home: Home
    ) -> None:
        # Given: a check and an Edit, sibling calls of one response, then the check again
        main = Transcript().human(0, "go")
        main.siblings(
            (80, "Bash", {"command": "just check"}, 150),
            (90, "Edit", {"file_path": "/repo/src/Main.hs"}, 151),
        )
        _ = main.bash(160, "just check", 220)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 0, 0m." in report

    def test_an_edit_sent_before_a_full_check_in_one_response_keeps_the_test_out_of_the_chain(
        self, home: Home
    ) -> None:
        # Given: a test step, then an Edit and a full check, sibling calls of one response
        main = Transcript().human(0, "go")
        _ = main.bash(10, "nix run .#test", 70)
        main.siblings(
            (80, "Edit", {"file_path": "/repo/src/Main.hs"}, 91),
            (90, "Bash", {"command": "just check"}, 150),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert (
            "Build/test steps run before a full check with no edit between: 0, 0m."
            in report
        )

    def test_an_edit_sent_after_a_test_in_one_response_keeps_the_test_out_of_the_chain(
        self, home: Home
    ) -> None:
        # Given: a test step and an Edit, sibling calls of one response, then a full check
        main = Transcript().human(0, "go")
        main.siblings(
            (80, "Bash", {"command": "nix run .#test"}, 150),
            (90, "Edit", {"file_path": "/repo/src/Main.hs"}, 151),
        )
        _ = main.bash(160, "just check", 220)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert (
            "Build/test steps run before a full check with no edit between: 0, 0m."
            in report
        )

    def test_a_sibling_of_a_check_that_changes_nothing_leaves_it_a_rerun(
        self, home: Home
    ) -> None:
        # Given: a Read beside a rerun of a check
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check", 70)
        main.siblings(
            (80, "Read", {"file_path": "/repo/src/Main.hs"}, 91),
            (90, "Bash", {"command": "just check"}, 150),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 1, 1m." in report

    def test_a_python_heredoc_writing_a_file_counts_as_a_change(
        self, home: Home
    ) -> None:
        # Given: three edits made by a Python heredoc, each between two runs of a check
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check", 70)
        _ = main.bash(
            80,
            "python3 - <<'EOF'\nfrom pathlib import Path\nPath('a.py').write_text('x')\nEOF",
            81,
        )
        _ = main.bash(90, "just check", 150)
        _ = main.bash(
            160,
            "python3 -I - <<EOF\nwith open('a.py', 'w') as f:\n    f.write('y')\nEOF",
            161,
        )
        _ = main.bash(170, "just check", 230)
        _ = main.bash(
            240,
            "python3 - <<'EOF'\nfrom pathlib import Path\nPath('a.py').open('w').write('z')\nEOF",
            241,
        )
        _ = main.bash(250, "just check", 310)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 0, 0m." in report

    def test_a_python_heredoc_that_only_reads_is_no_change(self, home: Home) -> None:
        # Given: two heredocs reading a file, each between two runs of a check
        main = Transcript().human(0, "go")
        _ = main.bash(10, "just check", 70)
        _ = main.bash(80, "python3 - <<'EOF'\nprint(open('data.txt').read())\nEOF", 81)
        _ = main.bash(90, "just check", 150)
        _ = main.bash(
            160,
            "python3 - <<'EOF'\nfrom pathlib import Path\nprint(Path('a.txt').open('r').read())\nEOF",
            161,
        )
        _ = main.bash(170, "just check", 230)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 2, 2m." in report


class TestFailures:
    def test_identical_failures_are_grouped_and_missing_tools_named(
        self, home: Home
    ) -> None:
        # Given: the same failing build twice, and a missing tool
        main = Transcript().human(0, "go")
        for t in (10, 20):
            _ = main.bash(
                t,
                "nix run .#build",
                t + 5,
                outcome=Outcome(
                    f"Exit code 1\nwarning: dirty\nerror: builder for '/nix/store/{'a' * 32}-x.drv' failed",
                    error=True,
                ),
            )
        _ = main.bash(
            30,
            "claude --version",
            31,
            outcome=Outcome(
                "Exit code 127\nbash: line 1: claude: command not found", error=True
            ),
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert "3 failed calls in 2 groups. Missing tools: claude (1)." in report
        assert row(report, "Failing tool calls", "2")[1:4] == [
            "Bash",
            "nix run .#build",
            "1",
        ]

    def test_a_background_command_failing_in_its_notification_is_a_failure(
        self, home: Home
    ) -> None:
        # Given
        main = Transcript().human(0, "go")
        bg = main.bash(10, "just check", 11, outcome=Outcome(background=True))
        _ = main.notify(
            100, bg, "failed", 'Background command "check" failed with exit code 2'
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert row(report, "Failing tool calls", "1")[1:4] == [
            "Bash",
            "just check",
            "2",
        ]


class TestPolling:
    def test_foreground_sleep_loops_and_repeated_pr_polls_are_counted(
        self, home: Home
    ) -> None:
        # Given
        main = Transcript().human(0, "go")
        _ = main.bash(10, "until gh pr checks 1; do sleep 30; done", 130)
        for t in (200, 300, 400):
            _ = main.bash(t, "gh pr checks 1", t + 2)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert (
            "sleep/until/while loops: 1 calls, 1 in the foreground taking 2m" in report
        )
        assert "agents polling it more than twice: s1 main: 4" in report


REVIEW_BRIEF = "invoke `pragmatic-review` with: the branch"
REVIEW_REPORT = """| # | Severity | What | Impact | Fix |
|---|----------|------|--------|-----|
| 1 | Major | `a.py:1` - invented defect | Invented impact | Invented fix |
| 2 | Minor | `b.py:2` - invented nit | Invented impact | Invented fix |

✅ **Met** - first invented requirement.

❌ **Not met** - second invented requirement.

⚠️ **Unverified** - third invented requirement.

Do not merge - Major row 1. 3 raised, 2 survived.
"""


def subagent(
    brief: str, usage: JsonObject | None = None, parent_agent: str | None = None
) -> Transcript:
    return Transcript(parent_agent=parent_agent).brief(5, brief).reply(6, usage)


def idle_main() -> Transcript:
    return Transcript().human(0, "go").reply(1)


def awaiting_subagent(done: float) -> Transcript:
    """A session whose first tool call runs `awaited_subagent` in the foreground until `done`."""
    main = Transcript().human(0, "go")
    _ = main.tool(1, "Agent", done, description="Implement")
    return main


def awaited_subagent() -> Transcript:
    return Transcript(parent="toolu_1").brief(0, "Implement")


def spawning_implementer() -> Transcript:
    main = Transcript().human(0, "go")
    _ = main.tool(
        1, "Agent", 2, outcome=Outcome(background=True), description="Implement parser"
    )
    return main


class TestLoopSteps:
    def test_each_subagent_lands_in_its_step(self, home: Home) -> None:
        # Given: one subagent per step, named as the loop names them
        main = Transcript().human(0, "go").reply(1, {"cache_read_input_tokens": 1000})
        home.session(
            "s1",
            main,
            {
                "a": worker("Research the parser", subagent("look around")),
                "b": worker("Implement parser", subagent("build it")),
                "c": worker(
                    "Refactor branch", subagent("invoke `refactor` on the branch")
                ),
                "d": worker("Review", subagent(REVIEW_BRIEF)),
                "e": worker("Review", subagent(REVIEW_BRIEF + " --fixes abc123")),
                "f": worker("Final review", subagent(REVIEW_BRIEF)),
                "g": worker(
                    "Fix rows 1 and 2",
                    subagent("fix them, then invoke `pragmatic-review` never"),
                ),
                "h": worker("Write PR description", subagent("describe it")),
                "i": worker("Sweep the floor", subagent("something else")),
            },
        )
        # When
        report = home.report()
        # Then
        for step in (
            "orchestrator",
            "research",
            "implement",
            "refactor",
            "review 1",
            "review 2",
            "final review",
            "fix",
            "pr description",
            "other",
        ):
            assert row(report, "Loop steps", step)[1:3] == ["1", "1"], step

    def test_a_role_agent_type_is_its_step_whatever_its_brief_says(
        self, home: Home
    ) -> None:
        # Given: no description or brief pattern matches any of them
        home.session(
            "s1",
            idle_main(),
            {
                "a": ("implementer", "Parser", subagent("build it")),
                "b": ("fixer", "Parser", subagent("row 1")),
                "c": ("review-lead", "Parser", subagent("the branch")),
                "d": ("review-lead", "Parser", subagent("the branch --fixes abc123")),
            },
        )
        # When
        report = home.report()
        # Then
        for step in ("implement", "fix", "review 1", "review 2"):
            assert row(report, "Loop steps", step)[1:3] == ["1", "1"], step

    def test_a_reviewer_under_a_review_lead_counts_under_its_pass(
        self, home: Home
    ) -> None:
        # Given: a review lead and the leaf reviewer it spawned, whose brief names no review
        home.session(
            "s1",
            idle_main(),
            {
                "a": ("review-lead", "Parser", subagent("the branch")),
                "b": (
                    "reviewer",
                    "Blockers",
                    subagent("read the bar", parent_agent="a"),
                ),
            },
        )
        # When / Then
        assert row(home.report(), "Loop steps", "review 1")[1:3] == ["2", "1"]

    def test_a_research_agent_type_is_research_whatever_its_brief_says(
        self, home: Home
    ) -> None:
        # Given: no description or brief pattern matches either
        home.session(
            "s1",
            idle_main(),
            {
                "a": ("researcher", "Pagination", subagent("topic=pagination")),
                "b": ("Explore", "Pagination", subagent("where is it")),
            },
        )
        # When / Then
        assert row(home.report(), "Loop steps", "research")[1:3] == ["2", "1"]

    def test_a_brief_invoking_the_researcher_skill_is_research(
        self, home: Home
    ) -> None:
        # Given
        home.session(
            "s1",
            idle_main(),
            {"a": worker("Pagination", subagent("Invoke `researcher` on pagination"))},
        )
        # When / Then
        assert row(home.report(), "Loop steps", "research")[1:3] == ["1", "1"]

    def test_a_researcher_under_an_orchestrator_subagent_stays_research(
        self, home: Home
    ) -> None:
        # Given: a subagent no pattern matches, and the researcher it spawned
        home.session(
            "s1",
            idle_main(),
            {
                "e": worker("Deliver issue 7", subagent("deliver it")),
                "r": (
                    "researcher",
                    "Pagination",
                    subagent("topic=pagination", parent_agent="e"),
                ),
            },
        )
        # When
        report = home.report()
        # Then
        assert row(report, "Loop steps", "research")[1:3] == ["1", "1"]
        assert row(report, "Loop steps", "other")[1:3] == ["1", "1"]

    def test_a_researcher_under_a_review_counts_as_the_review(self, home: Home) -> None:
        # Given
        home.session(
            "s1",
            idle_main(),
            {
                "r": worker("Review", subagent(REVIEW_BRIEF)),
                "c": (
                    "researcher",
                    "Check a claim",
                    subagent("topic=claim", parent_agent="r"),
                ),
            },
        )
        # When / Then
        assert row(home.report(), "Loop steps", "review 1")[1:3] == ["2", "1"]

    def test_a_child_counts_under_its_parents_step_with_its_tokens_and_wall(
        self, home: Home
    ) -> None:
        # Given: a review agent and the agent it spawned, 10 minutes each
        parent = subagent(REVIEW_BRIEF, {"cache_read_input_tokens": 2000}).reply(605)
        child = subagent(
            "the bar", {"cache_read_input_tokens": 1000}, parent_agent="r"
        ).reply(605)
        home.session(
            "s1",
            idle_main(),
            {"r": worker("Review", parent), "c": worker("Blockers", child)},
        )
        # When
        report = home.report()
        # Then
        assert row(report, "Loop steps", "review 1")[1:5] == [
            "2",
            "1",
            "0/3k/0/0",
            "20m",
        ]


class TestReviewYield:
    def report_with_review(self, home: Home, sub: Transcript) -> str:
        home.session("s1", idle_main(), {"r": worker("Review", sub)})
        return home.report()

    def test_a_report_handed_back_is_counted_in_its_pass(self, home: Home) -> None:
        # Given: a first review whose hand-back carries the fixed report format
        sub = subagent(REVIEW_BRIEF, {"cache_read_input_tokens": 5000}).handback(
            7, REVIEW_REPORT
        )
        # When
        report = self.report_with_review(home, sub)
        # Then: reports, tokens, raised, survived, severities, verdicts, do not merge, unparsed
        assert row(report, "Review yield", "review 1")[1:] == [
            "1",
            "0/5k/0/0",
            "3",
            "2",
            "1",
            "1",
            "0",
            "1",
            "1",
            "1",
            "1",
            "0",
        ]

    def test_a_second_pass_is_a_row_of_its_own(self, home: Home) -> None:
        # Given
        sub = subagent(REVIEW_BRIEF + " --fixes abc123").handback(
            7, "Ready to merge - nothing serious. 4 raised, 0 survived."
        )
        # When
        report = self.report_with_review(home, sub)
        # Then
        assert row(report, "Review yield", "review 2")[3:5] == ["4", "0"]
        assert "| review 1 |" not in section(report, "Review yield")

    def test_an_agent_with_no_hand_back_is_read_from_its_last_text(
        self, home: Home
    ) -> None:
        # Given: the report is the agent's last text, with no SubagentHandback call
        sub = subagent(REVIEW_BRIEF).reply(7, text=REVIEW_REPORT)
        # When
        report = self.report_with_review(home, sub)
        # Then
        assert row(report, "Review yield", "review 1")[3:5] == ["3", "2"]

    def test_a_report_without_the_verdict_arithmetic_counts_as_unparsed(
        self, home: Home
    ) -> None:
        # Given
        sub = subagent(REVIEW_BRIEF).handback(7, "Looks fine to me.")
        # When
        report = self.report_with_review(home, sub)
        # Then
        cells = row(report, "Review yield", "review 1")
        assert (cells[1], cells[3], cells[-1]) == ("1", "0", "1")

    def test_a_review_the_main_agent_ran_has_a_row_without_tokens(
        self, home: Home
    ) -> None:
        # Given
        main = (
            Transcript()
            .human(0, "go")
            .reply(1, {"cache_read_input_tokens": 9000}, text=REVIEW_REPORT)
        )
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert row(report, "Review yield", "run by main")[1:5] == ["1", "-", "3", "2"]

    def test_a_review_seconds_budget_is_not_a_second_pass(self, home: Home) -> None:
        # Given: a first review whose brief mentions seconds
        sub = subagent(REVIEW_BRIEF + ", 30 seconds per file").handback(
            7, REVIEW_REPORT
        )
        # When
        report = self.report_with_review(home, sub)
        # Then
        assert row(report, "Review yield", "review 1")[1] == "1"

    def test_a_hand_back_wins_over_text_written_after_it(self, home: Home) -> None:
        # Given: the last hand-back is the report, and text follows it
        sub = (
            subagent(REVIEW_BRIEF)
            .handback(7, "1 raised, 1 survived.")
            .handback(8, REVIEW_REPORT)
        )
        _ = sub.reply(9, text="Handed back.")
        # When
        report = self.report_with_review(home, sub)
        # Then
        assert row(report, "Review yield", "review 1")[3:5] == ["3", "2"]

    def test_a_review_agent_with_no_recorded_usage_still_shows_its_tokens(
        self, home: Home
    ) -> None:
        # Given: a review agent whose transcript recorded no usage
        sub = subagent(REVIEW_BRIEF).handback(7, REVIEW_REPORT)
        # When
        report = self.report_with_review(home, sub)
        # Then: zero tokens, not the "-" of a review with none to attribute
        assert row(report, "Review yield", "review 1")[2] == "0/0/0/0"

    def test_a_main_agent_report_without_the_arithmetic_keeps_its_rows_and_counts_as_unparsed(
        self, home: Home
    ) -> None:
        # Given: a report the main agent wrote, its verdict line drifted
        text = REVIEW_REPORT.replace(" 3 raised, 2 survived.", "")
        home.session("s1", Transcript().human(0, "go").reply(1, text=text))
        # When
        cells = row(home.report(), "Review yield", "run by main")
        # Then: reports, tokens, raised, survived, major, minor, then unparsed last
        assert cells[1:7] == ["1", "-", "0", "0", "1", "1"]
        assert cells[-1] == "1"

    def test_main_agent_text_without_rows_or_arithmetic_is_no_report(
        self, home: Home
    ) -> None:
        # Given
        home.session(
            "s1",
            Transcript()
            .human(0, "go")
            .reply(1, text="Major refactor done | see the PR"),
        )
        # When / Then
        assert "run by main" not in section(home.report(), "Review yield")

    def test_a_review_under_an_orchestrator_subagent_is_counted_with_its_own_tree(
        self, home: Home
    ) -> None:
        # Given: an orchestrator subagent, the review it spawned, and that review's tests agent
        finding = "a.py:1\nseverity    major\nclaim       invented\n"
        home.session(
            "s1",
            idle_main(),
            {
                "o": worker(
                    "Run the loop",
                    subagent("drive the loop", {"cache_read_input_tokens": 9000}),
                ),
                "r": worker(
                    "Review",
                    subagent(
                        REVIEW_BRIEF,
                        {"cache_read_input_tokens": 2000},
                        parent_agent="o",
                    ).handback(7, REVIEW_REPORT),
                ),
                "t": worker(
                    "Tests agent",
                    subagent(
                        "the bar", {"cache_read_input_tokens": 1000}, parent_agent="r"
                    ).handback(7, finding),
                ),
            },
        )
        # When
        report = home.report()
        # Then: the review and its child, without the orchestrator's tokens
        assert row(report, "Review yield", "review 1")[1:7] == [
            "1",
            "0/3k/0/0",
            "3",
            "2",
            "1",
            "1",
        ]
        assert row(report, "Loop steps", "review 1")[1] == "2"
        assert row(report, "Review yield", "tests")[1] == "1"

    def test_inner_agents_are_counted_by_type(self, home: Home) -> None:
        # Given: a review agent, its tests agent with a finding, its requirement agent with a verdict,
        # and its blockers agent finding nothing
        finding = "a.py:1\nseverity    major\nclaim       invented\n"
        verdict = (
            "requirement  invented\nverdict      unverified\nexamined     nothing\n"
        )
        home.session(
            "s1",
            idle_main(),
            {
                "r": worker(
                    "Review", subagent(REVIEW_BRIEF).handback(7, REVIEW_REPORT)
                ),
                "t": worker(
                    "Tests agent",
                    subagent("the bar", parent_agent="r").handback(7, finding),
                ),
                "q": worker(
                    "Requirement 1",
                    subagent("the bar", parent_agent="r").handback(7, verdict),
                ),
                "b": worker(
                    "Blockers",
                    subagent("the bar", parent_agent="r").handback(7, "NONE"),
                ),
            },
        )
        # When
        report = home.report()

        # Then: runs, major, minor, nit, runs with a finding, not met, unverified
        def cells(name: str) -> list[str]:
            return [row(report, "Review yield", name)[i] for i in (1, 3, 4, 5, 6, 7, 8)]

        assert cells("tests") == ["1", "1", "0", "0", "1", "0", "0"]
        assert cells("requirement") == ["1", "0", "0", "0", "0", "0", "1"]
        assert cells("blockers") == ["1", "0", "0", "0", "0", "0", "0"]


class TestAfterHandback:
    def test_only_prompts_after_the_first_gh_pr_ready_count(self, home: Home) -> None:
        # Given: a prompt before the first `gh pr ready`, then free text and two commands
        # after it, a second ready among them
        main = Transcript().human(0, "go").human(5, "also this")
        _ = main.bash(10, "gh pr ready 1", 11)
        _ = main.human(20, "why this?")
        _ = main.bash(25, "gh pr ready 1", 26)
        _ = main.command(30, "final-review").command(40, "give-feedback").reply(50)
        home.session("s1", main)
        home.session(
            "s2", Transcript().human(0, "no ready here").human(5, "more").reply(6)
        )
        # When
        report = home.report()
        # Then
        assert (
            "Sessions that ran `gh pr ready`: 1, with a human prompt after it: 1"
            in report
        )
        assert (
            "Human prompts after it: 3: 1 free text, /final-review 1, /give-feedback 1"
            in report
        )

    def test_a_ready_run_by_a_subagent_counts(self, home: Home) -> None:
        # Given
        main = Transcript().human(0, "go").human(100, "looks wrong").reply(101)
        sub = subagent("finish it")
        _ = sub.bash(50, "gh pr ready 1", 51)
        home.session("s1", main, {"a": worker("Finish", sub)})
        # When
        report = home.report()
        # Then
        assert "Human prompts after it: 1: 1 free text" in report


class TestCommunication:
    def two_agents_run(self, home: Home, *commands: str) -> None:
        first, second = subagent("look"), subagent("look")
        for t, command in enumerate(commands):
            _ = first.bash(7 + t, command, 8 + t, outcome=Outcome("x" * 1000))
            _ = second.bash(7 + t, command, 8 + t, outcome=Outcome("x" * 1000))
        home.session(
            "s1",
            idle_main(),
            {"a": worker("Audit a", first), "b": worker("Audit b", second)},
        )

    def test_brief_and_hand_back_sizes_are_reported_by_type_and_step(
        self, home: Home
    ) -> None:
        # Given: two implementers, one over the hand-back limit, one too thin
        home.session(
            "s1",
            idle_main(),
            {
                "a": worker(
                    "Implement a", subagent("word " * 100).handback(7, "word " * 400)
                ),
                "b": worker("Implement b", subagent("word " * 200).handback(7, "done")),
            },
        )
        # When
        report = home.report()
        # Then: agents, median and max brief, median and max hand-back, over the limit, under the floor
        assert row(report, "Agent communication", "general-purpose")[1:] == [
            "implement",
            "2",
            "150",
            "200",
            "200",
            "400",
            "1",
            "1",
        ]

    def test_a_large_hand_back_is_priced_by_the_parent_calls_after_it(
        self, home: Home
    ) -> None:
        # Given: a 400-word hand-back at 7s and two parent calls after it, one before
        main = Transcript().human(0, "go")
        _ = main.tool(
            1, "Agent", 2, outcome=Outcome(background=True), description="Research x"
        )
        _ = main.bash(20, "true", 21)
        _ = main.bash(30, "true", 31)
        sub = subagent("look").handback(7, "word " * 400)
        home.session("s1", main, {"a": worker("Research x", sub)})
        # When
        report = home.report()
        # Then: 2000 chars is 500 tokens, sent twice more
        assert (
            "Hand-backs over 300 words: 1, 2k chars, about 1k tokens sent again"
            in report
        )

    def test_a_hand_back_pointing_at_a_notes_file_is_counted(self, home: Home) -> None:
        # Given
        sub = subagent("look").handback(
            7, "Ranked index in /tmp/topic/notes.md, top item first."
        )
        home.session("s1", idle_main(), {"a": worker("Research x", sub)})
        # When
        report = home.report()
        # Then
        assert "Hand-backs pointing at a notes file: 1" in report

    def test_a_follow_up_message_to_a_subagent_is_counted(self, home: Home) -> None:
        # Given
        main = Transcript().human(0, "go")
        _ = main.tool(1, "SendMessage", 2, to="a", message="you also need x")
        home.session("s1", main, {"a": worker("Research x", subagent("look"))})
        # When
        report = home.report()
        # Then
        assert "Follow-up messages to a subagent: 1" in report

    def report_with_implementer(
        self, home: Home, main: Transcript, *others: Transcript
    ) -> str:
        """The report of `main` and an implementer that hands back at 7s, naming `parser.py`."""
        implementer = subagent("build it").handback(
            7, "Changed src/parser.py, tests pass."
        )
        agents = {"a": worker("Implement parser", implementer)}
        home.session(
            "s1",
            main,
            agents
            | {f"b{i}": worker("Refactor branch", t) for i, t in enumerate(others)},
        )
        return home.report()

    def test_a_parent_rereading_a_named_file_or_a_diff_is_a_re_read(
        self, home: Home
    ) -> None:
        # Given: the parent reads the named file, an unnamed file, and a diff
        main = spawning_implementer()
        _ = main.tool(
            10, "Read", 11, file_path="/repo/src/parser.py", outcome=Outcome("x" * 500)
        )
        _ = main.tool(
            12, "Read", 13, file_path="/repo/src/other.py", outcome=Outcome("x" * 500)
        )
        _ = main.bash(90, "git diff HEAD~1", 91, outcome=Outcome("y" * 300))
        # When
        report = self.report_with_implementer(home, main)
        # Then: hand-backs, re-reads, re-read chars
        assert row(report, "Agent communication", "implement")[1:4] == ["1", "2", "800"]

    def test_a_diff_of_another_worktree_is_a_re_read(self, home: Home) -> None:
        # Given: the parent diffs a path it named with `git -C`
        main = spawning_implementer()
        _ = main.bash(
            90, "git -C /repo/worktree diff HEAD~1", 91, outcome=Outcome("y" * 300)
        )
        # When
        report = self.report_with_implementer(home, main)
        # Then: hand-backs, re-reads, re-read chars
        assert row(report, "Agent communication", "implement")[1:4] == ["1", "1", "300"]

    def test_a_parent_rerunning_a_check_is_a_re_verify(self, home: Home) -> None:
        # Given
        main = spawning_implementer()
        _ = main.bash(20, "just check", 80)
        # When
        report = self.report_with_implementer(home, main)
        # Then: re-verifies, re-verify time
        assert row(report, "Agent communication", "implement")[4:6] == ["1", "1m"]

    def test_a_read_after_the_next_spawn_answers_no_hand_back(self, home: Home) -> None:
        # Given: the named file is read after a later spawn that is still running
        main = spawning_implementer()
        _ = main.tool(
            100,
            "Agent",
            101,
            outcome=Outcome(background=True),
            description="Refactor branch",
        )
        _ = main.tool(
            120,
            "Read",
            121,
            file_path="/repo/src/parser.py",
            outcome=Outcome("x" * 500),
        )
        refactorer = (
            Transcript()
            .brief(110, "invoke `refactor`")
            .reply(111)
            .handback(200, "Nothing to change.")
        )
        # When
        report = self.report_with_implementer(home, main, refactorer)
        # Then
        assert row(report, "Agent communication", "implement")[1:6] == [
            "1",
            "0",
            "0",
            "0",
            "0m",
        ]
        assert row(report, "Agent communication", "refactor")[1:6] == [
            "1",
            "0",
            "0",
            "0",
            "0m",
        ]

    def test_a_spawn_repeating_the_step_after_its_hand_back_is_counted_but_parallel_ones_are_not(
        self, home: Home
    ) -> None:
        # Given: two research agents in parallel, then a third after both returned
        def research(start: float, end: float) -> Transcript:
            return Transcript().brief(start, "look").reply(end)

        home.session(
            "s1",
            idle_main(),
            {
                "a": worker("Research a", research(5, 50)),
                "b": worker("Research b", research(6, 60)),
                "c": worker("Research c", research(70, 80)),
            },
        )
        # When
        report = home.report()
        # Then
        assert row(report, "Agent communication", "research")[-1] == "1"

    def test_the_same_read_by_two_agents_is_repeated_work(self, home: Home) -> None:
        # Given: two agents read one file; the first also reads a file nobody else does
        first = subagent("look")
        _ = first.tool(
            7, "Read", 8, file_path="/repo/big.py", outcome=Outcome("x" * 1000)
        )
        _ = first.tool(
            9, "Read", 10, file_path="/repo/own.py", outcome=Outcome("x" * 1000)
        )
        second = subagent("look")
        _ = second.tool(
            7, "Read", 8, file_path="/repo/big.py", outcome=Outcome("x" * 1000)
        )
        home.session(
            "s1",
            idle_main(),
            {"a": worker("Audit a", first), "b": worker("Audit b", second)},
        )
        # When
        report = home.report()
        # Then
        assert "by two or more agents of a session: 1, 1k chars repeated." in report
        assert row(report, "Agent communication", "s1")[1:] == [
            "/repo/big.py",
            "2",
            "2",
            "1k",
        ]

    def test_the_same_read_by_the_main_agent_and_a_subagent_is_repeated_work(
        self, home: Home
    ) -> None:
        # Given
        main = Transcript().human(0, "go")
        _ = main.tool(
            1, "Read", 2, file_path="/repo/big.py", outcome=Outcome("x" * 1000)
        )
        sub = subagent("look")
        _ = sub.tool(
            7, "Read", 8, file_path="/repo/big.py", outcome=Outcome("x" * 1000)
        )
        home.session("s1", main, {"a": worker("Audit a", sub)})
        # When
        report = home.report()
        # Then
        assert row(report, "Agent communication", "s1")[1:] == [
            "/repo/big.py",
            "2",
            "2",
            "1k",
        ]

    def test_a_read_command_run_by_two_agents_is_repeated_work_in_any_form(
        self, home: Home
    ) -> None:
        # Given: two agents running one read command, chained, then through `git -C`
        self.two_agents_run(
            home,
            "cd /repo && sed -n 1,40p big.py 2>/dev/null | head -5 || true",
            "git -C /repo log -1",
        )
        # When
        report = home.report()
        # Then
        assert "by two or more agents of a session: 2, 2k chars repeated." in report

    def test_a_command_outside_the_read_list_is_no_repeated_read(
        self, home: Home
    ) -> None:
        # Given: two agents running the same commands, none of them a read
        self.two_agents_run(
            home,
            "git push -u origin HEAD",
            "rm -f /repo/big.py",
            "rg foo /repo > /tmp/hits",
            "cd /repo",
        )
        # When
        report = home.report()
        # Then
        assert "by two or more agents of a session: 0, 0 chars repeated." in report

    def test_an_implementer_rereading_what_research_read_is_a_split(
        self, home: Home
    ) -> None:
        # Given: research reads two files, then an implementer reads one of them through
        # Bash, and an earlier implementer reads the other before research finished
        research = Transcript().brief(50, "look").reply(51)
        _ = research.tool(52, "Read", 53, file_path="/repo/a.py")
        _ = research.tool(54, "Read", 55, file_path="/repo/b.py")
        late = Transcript().brief(100, "build").reply(101)
        _ = late.bash(102, "sed -n 1,40p /repo/a.py", 103)
        early = Transcript().brief(5, "build").reply(6)
        _ = early.tool(7, "Read", 8, file_path="/repo/b.py")
        home.session(
            "s1",
            idle_main(),
            {
                "r": worker("Research parser", research),
                "l": worker("Implement late", late),
                "e": worker("Implement early", early),
            },
        )
        # When
        report = home.report()
        # Then
        assert (
            "Implementers reading files a research agent read: 1, 1 files between them"
            in report
        )


class TestWindow:
    def session_at(
        self,
        home: Home,
        sid: str,
        t: float,
        command: str | None = None,
        cwd: str = "/home/dev/repos/demo",
    ) -> None:
        main = Transcript(cwd=cwd)
        _ = main.command(t, command) if command else main.human(t, "work")
        home.session(sid, main.reply(t + 60))

    def sessions(self, report: str) -> set[str]:
        return {
            sid for sid in ("old", "prev", "work", "current") if f"| {sid} |" in report
        }

    def test_default_window_starts_at_the_previous_self_improve_and_skips_the_current(
        self, home: Home
    ) -> None:
        # Given
        self.session_at(home, "old", 0)
        self.session_at(home, "prev", 1000, "self-improve")
        self.session_at(home, "work", 2000)
        self.session_at(home, "current", 3000, "self-improve")
        # When / Then
        assert self.sessions(home.report()) == {"prev", "work"}

    def test_without_a_previous_self_improve_everything_but_the_current_is_reported(
        self, home: Home
    ) -> None:
        # Given
        self.session_at(home, "old", 0)
        self.session_at(home, "current", 3000, "self-improve")
        # When / Then
        assert self.sessions(home.report()) == {"old"}

    def test_a_long_lived_current_session_is_ordered_by_its_invocation_not_its_start(
        self, home: Home
    ) -> None:
        # Given a session that started first but invoked /self-improve last
        home.session(
            "current",
            Transcript()
            .human(0, "work")
            .reply(60)
            .command(3000, "self-improve")
            .reply(3060),
        )
        self.session_at(home, "prev", 1000, "self-improve")
        self.session_at(home, "work", 2000)
        # When / Then
        assert self.sessions(home.report()) == {"prev", "work"}

    def test_two_runs_in_one_session_report_the_work_between_them(
        self, home: Home
    ) -> None:
        # Given
        self.session_at(home, "old", 0)
        home.session(
            "current",
            Transcript()
            .command(1000, "self-improve")
            .reply(1060)
            .human(2000, "work")
            .reply(2060)
            .command(3000, "self-improve")
            .reply(3060),
        )
        # When
        report = home.report()
        # Then
        assert self.sessions(report) == {"current"}
        assert row(report, "Sessions", "current")[3] == "18m"

    def test_since_and_project_narrow_the_window(self, home: Home) -> None:
        # Given
        self.session_at(home, "old", 0)
        self.session_at(home, "prev", 1000, cwd="/home/dev/repos/other")
        self.session_at(home, "work", 2000)
        # When
        report = home.report("--since", at(500), "--project", "demo")
        # Then
        assert self.sessions(report) == {"work"}


COSTS_1K: JsonObject = {"input_tokens": 1000}


class TestQualityModes:
    def test_each_wire_form_is_its_own_row(self, home: Home) -> None:
        # Given
        home.session(
            "s1",
            idle_main(),
            {
                "a": worker("A", subagent("Quality: POC. Spike it.", COSTS_1K)),
                "b": worker(
                    "B", subagent("Quality: Balanced, Trivial\nImplement it.", COSTS_1K)
                ),
                "c": worker(
                    "C", subagent("Quality: Max, not Trivial\nReview it.", COSTS_1K)
                ),
            },
        )
        # When
        report = home.report()
        # Then
        for mode in ("POC", "Balanced, Trivial", "Max, not Trivial"):
            cells = row(report, "Cost by Quality mode", mode)
            assert [cells[1], cells[4]] == ["1", "1k"], mode

    def test_the_placeholder_in_a_pasted_rule_is_not_a_mode(self, home: Home) -> None:
        # Given
        home.session(
            "s1",
            idle_main(),
            {"a": worker("A", subagent("Every brief carries `Quality: <mode>`."))},
        )
        # When / Then
        assert row(home.report(), "Cost by Quality mode", "(none stated)")[1:4] == [
            "1",
            "0",
            "2",
        ]

    def test_a_child_with_no_mode_takes_its_parents(self, home: Home) -> None:
        # Given: a sibling stating another mode, which the main agent takes as the session's
        home.session(
            "s1",
            idle_main(),
            {
                "p": worker("P", subagent("Quality: POC. Go.", COSTS_1K)),
                "c": worker("C", subagent("no mode", COSTS_1K, parent_agent="p")),
                "m1": worker("M1", subagent("Quality: Max. Go.")),
                "m2": worker("M2", subagent("Quality: Max. Go.")),
                "m3": worker("M3", subagent("Quality: Max. Go.")),
            },
        )
        # When / Then
        assert row(home.report(), "Cost by Quality mode", "POC")[3:5] == ["2", "2k"]

    def test_the_main_agent_takes_the_mode_most_subagents_state(
        self, home: Home
    ) -> None:
        # Given
        main = Transcript().human(0, "go").reply(1, COSTS_1K)
        home.session(
            "s1",
            main,
            {
                "a": worker("A", subagent("Quality: Max. Go.")),
                "b": worker("B", subagent("Quality: Max. Go.")),
                "c": worker("C", subagent("Quality: POC. Go.")),
            },
        )
        # When
        report = home.report()
        # Then
        assert row(report, "Cost by Quality mode", "Max")[3:5] == ["3", "1k"]
        assert row(report, "Cost by Quality mode", "POC")[3:5] == ["1", "0"]

    def test_a_session_that_left_trivial_counts_its_main_agent_as_left(
        self, home: Home
    ) -> None:
        # Given: one agent on each side of the escalation, the later one last
        main = Transcript().human(0, "go").reply(1, COSTS_1K)
        early = Transcript().brief(5, "Quality: Balanced, Trivial\nGo.").reply(6)
        late = Transcript().brief(50, "Quality: Balanced, not Trivial\nGo.").reply(51)
        home.session("s1", main, {"z": worker("Z", early), "a": worker("A", late)})
        # When / Then
        assert row(home.report(), "Cost by Quality mode", "Balanced, not Trivial")[
            3:5
        ] == ["2", "1k"]

    def test_the_per_pr_median_splits_a_sessions_cost_and_skips_sessions_with_no_pr(
        self,
        home: Home,
    ) -> None:
        # Given: 2k over two PRs, 4k over one PR, and a session that opened none
        two = Transcript().human(0, "Quality: Max").reply(1, {"input_tokens": 2000})
        _ = two.bash(2, "gh pr create --fill", 3)
        _ = two.bash(4, "gh pr create --fill", 5)
        home.session("s1", two)
        one = Transcript().human(0, "Quality: Max").reply(1, {"input_tokens": 4000})
        _ = one.bash(2, "gh pr create --fill", 3)
        home.session("s2", one)
        home.session(
            "s3",
            Transcript().human(0, "Quality: Max").reply(1, {"input_tokens": 90_000}),
        )
        # When / Then: the median of 1k and 4k
        assert row(home.report(), "Cost by Quality mode", "Max")[1:6] == [
            "3",
            "3",
            "3",
            "96k",
            "2k",
        ]

    def test_a_failed_gh_pr_create_opened_no_pr(self, home: Home) -> None:
        # Given
        main = Transcript().human(0, "Quality: Max").reply(1)
        _ = main.bash(
            2, "gh pr create --fill", 3, outcome=Outcome("Exit code 1", error=True)
        )
        home.session("s1", main)
        # When / Then
        assert row(home.report(), "Cost by Quality mode", "Max")[2] == "0"

    def test_a_review_that_reports_a_trivial_sweep_unbriefed_counts_as_self_activated(
        self,
        home: Home,
    ) -> None:
        # Given: one review activating it, one briefed Trivial
        report = "Security: Trivial - sweep clean, code tier\n0 raised, 0 survived."
        home.session(
            "s1",
            idle_main(),
            {
                "a": worker(
                    "Review",
                    subagent("Quality: Balanced. " + REVIEW_BRIEF, COSTS_1K).handback(
                        7, report
                    ),
                ),
                "b": worker(
                    "Review",
                    subagent("Quality: Balanced, Trivial. " + REVIEW_BRIEF).handback(
                        7, report
                    ),
                ),
            },
        )
        # When / Then
        assert (
            "Reviews that activated Trivial themselves: 1, 1k effective."
            in home.report()
        )

    def test_a_review_briefed_not_trivial_can_still_activate_it(
        self, home: Home
    ) -> None:
        # Given: a review that reports a sweep though its brief left Trivial
        report = "Security: Trivial - sweep clean, code tier\n0 raised, 0 survived."
        home.session(
            "s1",
            idle_main(),
            {
                "a": worker(
                    "Review",
                    subagent(
                        "Quality: Balanced, not Trivial. " + REVIEW_BRIEF, COSTS_1K
                    ).handback(7, report),
                ),
            },
        )
        # When / Then
        assert (
            "Reviews that activated Trivial themselves: 1, 1k effective."
            in home.report()
        )

    def test_the_section_says_what_it_cannot_count(self, home: Home) -> None:
        # Given
        home.session("s1", idle_main())
        # When / Then
        assert "Not counted: Trivial self-activated outside a review" in home.report()


class TestStartUp:
    def test_the_split_adds_up_to_the_first_call(self, home: Home) -> None:
        # Given: 2k of instructions, 3k of listing in a first call of 40k, and a later larger call
        agent = (
            Transcript()
            .brief(5, "go")
            .startup(5, 8000, 12_000)
            .reply(6, {"cache_creation_input_tokens": 40_000})
        )
        _ = agent.reply(7, {"cache_read_input_tokens": 90_000})
        home.session("s1", idle_main(), {"a": worker("A", agent)})
        # When / Then
        assert row(home.report(), "Start-up size", "general-purpose")[1:] == [
            "1",
            "40k",
            "40k",
            "2k",
            "3k",
            "35k",
        ]

    def test_p50_and_p90_rank_the_agents_of_a_type(self, home: Home) -> None:
        # Given: ten agents from 10k to 100k
        home.session(
            "s1",
            idle_main(),
            {
                f"a{k}": (
                    "researcher",
                    "A",
                    subagent("go", {"input_tokens": k * 10_000}),
                )
                for k in range(1, 11)
            },
        )
        # When / Then
        assert row(home.report(), "Start-up size", "researcher")[1:4] == [
            "10",
            "55k",
            "90k",
        ]

    def test_a_listing_delta_after_the_first_call_is_not_start_up(
        self, home: Home
    ) -> None:
        # Given
        agent = (
            Transcript()
            .brief(5, "go")
            .reply(6, {"input_tokens": 1000})
            .startup(7, 8000, 12_000)
        )
        home.session("s1", idle_main(), {"a": worker("A", agent)})
        # When / Then
        assert row(home.report(), "Start-up size", "general-purpose")[4:6] == ["0", "0"]

    def test_an_api_error_line_is_not_the_first_call(self, home: Home) -> None:
        # Given: a first response with no usage
        agent = Transcript().brief(5, "go").reply(6).reply(7, {"input_tokens": 1000})
        home.session("s1", idle_main(), {"a": worker("A", agent)})
        # When / Then
        assert row(home.report(), "Start-up size", "general-purpose")[1:3] == [
            "1",
            "1k",
        ]


class TestCompare:
    SPLIT: ClassVar[int] = 10_000

    def sessions(self, home: Home, n: int, start: float, tokens: int) -> None:
        for k in range(n):
            main = (
                Transcript()
                .human(start + k, "Quality: Max")
                .reply(start + k + 1, {"input_tokens": tokens})
            )
            home.session(f"s{start:.0f}-{k}", main)

    def report(self, home: Home) -> str:
        return home.report("--since", at(0), "--compare", at(self.SPLIT))

    def test_medians_sit_side_by_side_with_n(self, home: Home) -> None:
        # Given
        self.sessions(home, 5, 0, 1000)
        self.sessions(home, 6, self.SPLIT + 1, 3000)
        # When / Then
        assert row(self.report(home), "Before and after", "effective per session")[
            1:
        ] == ["5", "1k", "6", "3k"]

    def test_a_side_below_the_minimum_says_not_enough_data(self, home: Home) -> None:
        # Given: one short of the minimum after the split
        self.sessions(home, 5, 0, 1000)
        self.sessions(home, 4, self.SPLIT + 1, 3000)
        # When / Then
        assert row(self.report(home), "Before and after", "effective per session")[
            1:
        ] == ["5", "1k", "4", "not enough data"]

    def test_a_session_starting_at_the_split_counts_after(self, home: Home) -> None:
        # Given
        self.sessions(home, 1, self.SPLIT, 1000)
        # When / Then
        assert row(self.report(home), "Before and after", "effective per session")[
            1:
        ] == ["0", "not enough data", "1", "not enough data"]

    def pr_sessions(self, home: Home, n: int, start: float, tokens: int) -> None:
        for k in range(n):
            main = (
                Transcript()
                .human(start, "go")
                .reply(start + 1, {"input_tokens": tokens})
            )
            _ = main.bash(start + 2, "gh pr create --fill", start + 3)
            researcher = (
                Transcript()
                .brief(start + 5, "go")
                .reply(start + 6, {"input_tokens": tokens})
            )
            home.session(
                f"pr{start:.0f}-{k}", main, {"a": ("researcher", "A", researcher)}
            )

    def test_cost_per_pr_by_mode_and_start_up_by_type_are_compared(
        self, home: Home
    ) -> None:
        # Given
        self.pr_sessions(home, 5, 0, 1000)
        self.pr_sessions(home, 5, self.SPLIT + 1, 3000)
        # When
        report = self.report(home)
        # Then: a PR costs the main agent plus its researcher
        assert row(report, "Before and after", "first-call context, researcher")[
            1:
        ] == ["5", "1k", "5", "3k"]
        assert row(report, "Before and after", "effective per PR, (none stated)")[
            1:
        ] == ["5", "2k", "5", "6k"]

    def test_the_section_is_absent_without_the_flag(self, home: Home) -> None:
        # Given
        self.sessions(home, 1, 0, 1000)
        # When / Then
        assert "Before and after" not in home.report()


class TestBashCommandsAreReadAsBash:
    def ran_twice(self, home: Home, command: str) -> None:
        main = Transcript().human(0, "go")
        _ = main.bash(10, command, 70)
        _ = main.bash(100, command, 160)
        home.session("s1", main)

    @pytest.mark.parametrize(
        ("command", "key"),
        [
            pytest.param(
                "if just check; then echo ok; fi", "just check", id="in-an-if"
            ),
            pytest.param(
                "for i in 1 2; do just test; done", "just test", id="in-a-for-loop"
            ),
            pytest.param("just \\\ncheck", "just check", id="over-a-line-continuation"),
            pytest.param("just check &", "just check", id="in-the-background"),
            pytest.param(
                "just check &> /tmp/log",
                "just check",
                id="with-both-streams-redirected",
            ),
            pytest.param(
                "# then; just check next\njust test", "just test", id="under-a-comment"
            ),
        ],
    )
    def test_a_check_is_counted_whatever_the_syntax_around_it(
        self, home: Home, command: str, key: str
    ) -> None:
        # Given: the same call twice, with nothing changed between
        self.ran_twice(home, command)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 1, 1m." in report
        assert f"| {key} | no edit |" in report

    @pytest.mark.parametrize(
        "command",
        [
            pytest.param(
                'git commit -m "docs; just check; done"', id="between-semicolons"
            ),
            pytest.param('git commit -m "docs\n\njust check\n"', id="on-its-own-line"),
        ],
    )
    def test_a_quoted_operator_does_not_start_a_check(
        self, home: Home, command: str
    ) -> None:
        # Given: a check named in a message, twice, with nothing changed between
        self.ran_twice(home, command)
        # When
        report = home.report()
        # Then
        assert "Reruns with nothing changed since the same check: 0, 0m." in report

    def test_a_heredoc_body_is_not_a_check(self, home: Home) -> None:
        # Given: a check spelled in a note, not run
        main = Transcript().human(0, "go")
        _ = main.bash(10, "cat > notes <<'EOF'\nnix flake check\nEOF", 11)
        home.session("s1", main)
        # When
        report = home.report()
        # Then
        assert row(report, "Wall time per Bash command", "cat")[1] == "1"


REALISTIC = [
    "just check",
    "nix flake check",
    "nix develop -c just check",
    "nix develop .#ci -c just check",
    "nix build --no-link .#checks.x86_64-linux.typos",
    "nix run .#test -- Lexer",
    "nix run .#quick-typecheck",
    "git -C /repo status --short",
    "git add -N new.py && git commit -m 'Add new: a; b'",
    "git commit -m \"$(cat <<'EOF'\nFix the parser\n\njust check is green\nEOF\n)\"",
    'git commit -m "docs\n\njust check\n"',
    "gh pr create --title 'Fix' --body-file /tmp/body.md",
    "gh pr create --title Fix --body \"$(cat <<'EOF'\n## What\nnix flake check\nEOF\n)\"",
    "gh pr checks 12 --watch",
    "gh pr view 12 --json number -q .number",
    "rg -n 'foo|bar' src | head -20",
    "grep -E 'a|b' file.txt | wc -l",
    "sed -n '10,20p' file.py",
    "cat README.md",
    "ls -la && pwd",
    "cd /repo && just test 2>&1 | tail -20",
    "cd /repo && just check > /tmp/out.log 2>&1",
    "just check &> /tmp/out.log",
    "just test | tee /tmp/out.log",
    "just build && just test",
    "just lint; just test",
    "just check || echo failed",
    "timeout 590 just check",
    "FOO=1 BAR=2 just test",
    "env FOO=1 cabal test",
    "cabal build all",
    "cargo clippy --all-targets",
    "cargo test -p foo -- --nocapture",
    "npm test",
    "npm run lint",
    "pnpm run build",
    "pnpm test",
    "python3 - <<'PY'\nimport json\nprint(json.dumps({}))\nPY",
    "python3 -c 'import sys; print(sys.version)'",
    "cat > notes <<'EOF'\nnix flake check\nEOF",
    "cat <<-EOF > f\n\tjust check\n\tEOF\necho done",
    "if just check; then echo ok; else echo no; fi",
    "if [ -f flake.nix ]; then nix flake check; fi",
    "[[ -f flake.nix ]] && nix flake check",
    "for i in 1 2 3; do just test; done",
    'for f in *.py; do ruff check "$f"; done',
    'while read -r f; do echo "$f"; done < list.txt',
    "until gh pr checks 12; do sleep 30; done",
    "while ! just test; do sleep 5; done",
    "! just lint",
    "(cd sub && just check)",
    "{ just test; just lint; } 2>&1 | tail",
    "just \\\n  check",
    "nix develop .#ci \\\n  -c just check",
    "just check &",
    "just test & just lint & wait",
    "sleep 5 && gh pr checks 12",
    "curl -s 'https://example.com/a?x=1&y=2' | jq .",
    "git log --oneline -5 | cat",
    "# run the suite; just check next\njust test",
    "# don't skip this\njust check; echo 'done'",
    "git diff --stat origin/main...HEAD",
    "xargs -n1 echo < list.txt",
    "mkdir -p out && touch out/a",
    "rm -rf build; just build",
]

SUBSTITUTION = "A statistic of top-level commands: reading `$(...)` needs real nesting."
LEADING_REDIRECT = "Nobody writes a redirect first, and it costs only a label."
ARITHMETIC = "`(( ))` holds no command, and only the label of a rare form is off."
QUOTED_NAME = "A quoted command name is obfuscation, not what an agent writes."
QUOTES_KEPT = "The key keeps the source's quotes: still one stable key per check."

# Where the two readings differ on purpose. An entry that stops differing fails.
ALLOWED_DIFFERENCES = {
    "x=$(gh pr checks 1)": SUBSTITUTION,
    "tee >(gzip > a.gz) < in": SUBSTITUTION,
    'for f in $(seq 3); do cat "$f"; done': SUBSTITUTION,
    'pr=$(gh pr view --json number -q .number); gh pr ready "$pr"': SUBSTITUTION,
    'echo "$(git rev-parse HEAD)"': SUBSTITUTION,
    "A=1 >f cat": LEADING_REDIRECT,
    "2>/dev/null cat f": LEADING_REDIRECT,
    ">out cat f": LEADING_REDIRECT,
    "(( i > 0 )) && echo y": ARITHMETIC,
    "sle\\\nep 60": QUOTED_NAME,
    'ec"ho" hi': QUOTED_NAME,
    "e\\cho hi": QUOTED_NAME,
    'nix run .#test -- --match "Lexer basics"': QUOTES_KEPT,
}

CORPUS = [command for group in PARSED.values() for command, _ in group]
AGREEING = sorted((set(CORPUS) | set(REALISTIC)) - set(ALLOWED_DIFFERENCES))


def by_regex(command: str) -> tuple[str, str]:
    return analyze.label(command), analyze.check_key(command)


def by_shfmt(command: str) -> tuple[str, str]:
    match parse(command):
        case Parsed(commands):
            found = [analyze.step(list(simple.words)) for simple in commands]
            steps = [step for step in found if step is not None]
            return analyze.label_of(command, steps), analyze.key_of(steps)
        case Unparsable(reason):
            pytest.fail(f"shfmt cannot read {command!r}: {reason}")


@pytest.mark.parametrize("command", AGREEING)
def test_label_and_check_key_read_a_command_as_shfmt_does(command: str) -> None:
    assert by_regex(command) == by_shfmt(command)


@pytest.mark.parametrize("command", list(ALLOWED_DIFFERENCES))
def test_an_allowed_difference_still_differs(command: str) -> None:
    assert by_regex(command) != by_shfmt(command)
