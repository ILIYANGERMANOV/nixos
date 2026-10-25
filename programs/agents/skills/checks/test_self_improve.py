"""Black-box tests for the self-improve analyzer, run by `checks.self-improve`.

Each test writes synthetic transcripts in Claude Code's on-disk layout, runs
the analyzer's CLI on them and asserts on the report it prints.

Usage: python3 -I test_self_improve.py <path to analyze.py>
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

ANALYZER = ""
BASE = datetime(2026, 1, 1, tzinfo=timezone.utc)


def at(seconds: float) -> str:
    return (BASE + timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


@dataclass
class Transcript:
    """Builds one agent's JSONL transcript; times are seconds after BASE."""

    cwd: str = "/home/dev/repos/demo"
    lines: list[dict] = field(default_factory=list)
    calls: int = 0

    def event(self, t: float, kind: str, **fields: object) -> Transcript:
        self.lines.append({"type": kind, "timestamp": at(t), "cwd": self.cwd, **fields})
        return self

    def human(self, t: float, text: str) -> Transcript:
        return self.event(t, "user", origin={"kind": "human"}, message={"role": "user", "content": text})

    def command(self, t: float, name: str) -> Transcript:
        return self.human(t, f"<command-message>{name}</command-message>\n<command-name>/{name}</command-name>")

    def reply(self, t: float, usage: dict | None = None, skill: str | None = None, content_lines: int = 1) -> Transcript:
        """One model response, written as Claude Code does: one line per content block."""
        self.calls += 1
        message = {"id": f"msg_{self.calls}", "role": "assistant", "content": [{"type": "text", "text": "ok"}],
                   "usage": usage or {}}
        for _ in range(content_lines):
            self.event(t, "assistant", message=message, attributionSkill=skill)
        return self

    def tool(self, t: float, name: str, done: float, *, result: str = "ok", error: bool = False,
             background: bool = False, **tool_input: object) -> str:
        """A tool call and its result. Returns the tool_use id."""
        self.calls += 1
        use_id = f"toolu_{self.calls}"
        self.event(t, "assistant", message={"id": f"msg_{self.calls}", "role": "assistant", "usage": {},
                                            "content": [{"type": "tool_use", "id": use_id, "name": name,
                                                         "input": tool_input}]})
        extra = {"backgroundTaskId": f"bg{self.calls}"} if background else {}
        self.event(done, "user", toolUseResult=extra,
                   message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": use_id,
                                                         "content": result, "is_error": error}]})
        return use_id

    def bash(self, t: float, command: str, done: float, **kw: object) -> str:
        return self.tool(t, "Bash", done, command=command, **kw)

    def notify(self, t: float, use_id: str, status: str, summary: str) -> Transcript:
        content = (f"<task-notification>\n<task-id>x</task-id>\n<tool-use-id>{use_id}</tool-use-id>\n"
                   f"<status>{status}</status>\n<summary>{summary}</summary>\n</task-notification>")
        return self.event(t, "queue-operation", operation="enqueue", content=content)


@dataclass
class Home:
    """A fake ~/.claude/projects holding sessions, each with optional subagents."""

    root: Path

    def session(self, sid: str, main: Transcript, subagents: dict[str, tuple[str, str, Transcript]] | None = None) -> None:
        project = self.root / ("-" + main.cwd.strip("/").replace("/", "-"))
        write(project / f"{sid}.jsonl", main)
        for agent_id, (kind, description, transcript) in (subagents or {}).items():
            base = project / sid / "subagents" / f"agent-{agent_id}"
            write(base.with_suffix(".jsonl"), transcript)
            base.with_suffix(".meta.json").write_text(json.dumps({"agentType": kind, "description": description}))

    def report(self, *args: str) -> str:
        run = subprocess.run([sys.executable, "-I", ANALYZER, "--root", str(self.root), *args],
                             capture_output=True, text=True, check=True)
        return run.stdout


def write(path: Path, transcript: Transcript) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(line) + "\n" for line in transcript.lines))


def row(report: str, section: str, first_cell: str) -> list[str]:
    """The cells of the row whose first cell is `first_cell`, in the section titled `section`."""
    body = report.split(f"## {section}", 1)[-1].split("\n## ", 1)[0]
    for line in body.splitlines():
        cells = [c.strip() for c in line.strip("|").split("|")]
        if line.startswith("|") and cells[0] == first_cell:
            return cells
    raise AssertionError(f"no row starting with {first_cell!r} in:\n{report}")


class Case(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Home(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()


class Tokens(Case):
    def test_a_response_split_over_content_lines_is_counted_once(self) -> None:
        # Given: one response written as three lines, and a second response
        main = Transcript().human(0, "go")
        main.reply(1, {"input_tokens": 10, "cache_read_input_tokens": 2000, "cache_creation_input_tokens": 300,
                       "output_tokens": 40}, content_lines=3)
        main.reply(2, {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 0})
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then: tokens are the sum of two responses, not four lines
        self.assertIn("main 15/3k/300/40", report)
        self.assertEqual(row(report, "Tokens by agent type", "main")[1:4], ["1", "2", "15/3k/300/40"])

    def test_subagent_tokens_are_reported_by_type_and_description(self) -> None:
        # Given: a session with one implementer subagent
        main = Transcript().command(0, "engineer").reply(1, {"cache_read_input_tokens": 1000})
        sub = Transcript().reply(5, {"cache_read_input_tokens": 2_000_000, "cache_creation_input_tokens": 50_000})
        sub.reply(6, {"cache_read_input_tokens": 3_000_000}, skill="engineering")
        self.home.session("s1", main, {"a1": ("general-purpose", "Implement parser", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Tokens by agent type", "general-purpose")[1:], ["1", "2", "0/5.0M/50k/0", "3.0M"])
        self.assertEqual(row(report, "Costliest subagents", "s1")[1:5], ["general-purpose", "Implement parser", "0/5.0M/50k/0", "3.0M"])
        self.assertEqual(row(report, "Tokens by skill", "engineering")[1:], ["1", "0/3.0M/0/0"])
        self.assertIn("/engineer", row(report, "Sessions", "s1")[5])


class WallTime(Case):
    def test_foreground_and_background_calls_are_timed_to_their_result_and_notification(self) -> None:
        # Given: a 90s foreground check and a background one finishing 300s after launch
        main = Transcript().human(0, "go")
        main.bash(10, "cd /repo && just check", 100)
        bg = main.bash(200, "just check 2>&1 | tail", 201, background=True, result="Command running in background")
        main.notify(500, bg, "completed", 'Background command "check" completed (exit code 0)')
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Wall time per Bash command", "just check")[1:6], ["1", "2m", "1", "5m", "300s"])

    def test_waiting_on_the_person_is_split_from_work(self) -> None:
        # Given: a 10 min gap before the person's second prompt and a 2 min question
        main = Transcript().human(0, "go").reply(60)
        main.human(660, "next")
        main.tool(700, "AskUserQuestion", 820)
        main.reply(3600)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then: 12 of the 60 minutes are waiting
        self.assertIn("Wall clock: 1.0h = work 0.8h + waiting on the person 0.2h", report)
        self.assertEqual(row(report, "Sessions", "s1")[3:5], ["60m", "12m"])


class RedundantChecks(Case):
    def test_reruns_are_flagged_only_when_nothing_but_docs_changed(self) -> None:
        # Given: a rerun with no edit, one after a doc edit, one after a code edit
        main = Transcript().human(0, "go")
        main.bash(10, "just check 2> /tmp/err.log", 70)
        main.bash(80, "cd /repo && just check > /tmp/a.log", 140)
        main.tool(150, "Edit", 151, file_path="/repo/README.md")
        main.bash(160, "just check", 220)
        main.tool(230, "Edit", 231, file_path="/repo/src/Main.hs")
        main.bash(240, "just check", 300)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 2, 2m.", report)
        self.assertIn("| just check | no edit |", report)
        self.assertIn("| just check | doc-only edit |", report)

    def test_an_edit_by_another_agent_of_the_session_counts_as_a_change(self) -> None:
        # Given: the orchestrator checks, its implementer edits, the orchestrator checks again
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 70)
        main.bash(200, "just check", 260)
        sub = Transcript()
        sub.tool(100, "Write", 101, file_path="/repo/src/New.hs")
        self.home.session("s1", main, {"a1": ("general-purpose", "Implement", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 0, 0m.", report)

    def test_steps_run_in_front_of_a_full_check_are_chains(self) -> None:
        # Given: build && check in one call, and a test run right before a check
        main = Transcript().human(0, "go")
        main.bash(10, "just build && just check", 100)
        main.tool(110, "Edit", 111, file_path="/repo/src/Main.hs")
        main.bash(120, "nix run .#test -- -m parser", 180)
        main.bash(190, "just check", 250)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Build/test steps run before a full check with no edit between: 2, 1m.", report)
        self.assertIn("| nix run .#test -- -m parser | 60s |", report)


class Failures(Case):
    def test_identical_failures_are_grouped_and_missing_tools_named(self) -> None:
        # Given: the same failing build twice, and a missing tool
        main = Transcript().human(0, "go")
        for t in (10, 20):
            main.bash(t, "nix run .#build", t + 5, error=True,
                      result=f"Exit code 1\nwarning: dirty\nerror: builder for '/nix/store/{'a' * 32}-x.drv' failed")
        main.bash(30, "claude --version", 31, error=True, result="Exit code 127\nbash: line 1: claude: command not found")
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("3 failed calls in 2 groups. Missing tools: claude (1).", report)
        self.assertEqual(row(report, "Failing tool calls", "2")[1:4], ["Bash", "nix run .#build", "1"])

    def test_a_background_command_failing_in_its_notification_is_a_failure(self) -> None:
        # Given
        main = Transcript().human(0, "go")
        bg = main.bash(10, "just check", 11, background=True)
        main.notify(100, bg, "failed", 'Background command "check" failed with exit code 2')
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Failing tool calls", "1")[1:4], ["Bash", "just check", "2"])


class Polling(Case):
    def test_foreground_sleep_loops_and_repeated_pr_polls_are_counted(self) -> None:
        # Given
        main = Transcript().human(0, "go")
        main.bash(10, "until gh pr checks 1; do sleep 30; done", 130)
        for t in (200, 300, 400):
            main.bash(t, "gh pr checks 1", t + 2)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("sleep/until/while loops: 1 calls, 1 in the foreground taking 2m", report)
        self.assertIn("agents polling it more than twice: s1 main: 4", report)


class Window(Case):
    def session_at(self, sid: str, t: float, command: str | None = None, cwd: str = "/home/dev/repos/demo") -> None:
        main = Transcript(cwd=cwd)
        if command:
            main.command(t, command)
        else:
            main.human(t, "work")
        self.home.session(sid, main.reply(t + 60))

    def sessions(self, report: str) -> set[str]:
        return {sid for sid in ("old", "prev", "work", "current") if f"| {sid} |" in report}

    def test_default_window_starts_at_the_previous_self_improve_and_skips_the_current(self) -> None:
        # Given
        self.session_at("old", 0)
        self.session_at("prev", 1000, "self-improve")
        self.session_at("work", 2000)
        self.session_at("current", 3000, "self-improve")
        # When / Then
        self.assertEqual(self.sessions(self.home.report()), {"prev", "work"})

    def test_without_a_previous_self_improve_everything_but_the_current_is_reported(self) -> None:
        # Given
        self.session_at("old", 0)
        self.session_at("current", 3000, "self-improve")
        # When / Then
        self.assertEqual(self.sessions(self.home.report()), {"old"})

    def test_a_long_lived_current_session_is_ordered_by_its_invocation_not_its_start(self) -> None:
        # Given a session that started first but invoked /self-improve last
        self.home.session("current", Transcript().human(0, "work").reply(60).command(3000, "self-improve").reply(3060))
        self.session_at("prev", 1000, "self-improve")
        self.session_at("work", 2000)
        # When / Then
        self.assertEqual(self.sessions(self.home.report()), {"prev", "work"})

    def test_two_runs_in_one_session_report_the_work_between_them(self) -> None:
        # Given
        self.session_at("old", 0)
        self.home.session("current", Transcript().command(1000, "self-improve").reply(1060)
                          .human(2000, "work").reply(2060).command(3000, "self-improve").reply(3060))
        # When
        report = self.home.report()
        # Then
        self.assertEqual(self.sessions(report), {"current"})
        self.assertEqual(row(report, "Sessions", "current")[3], "18m")

    def test_since_and_project_narrow_the_window(self) -> None:
        # Given
        self.session_at("old", 0)
        self.session_at("prev", 1000, cwd="/home/dev/repos/other")
        self.session_at("work", 2000)
        # When
        report = self.home.report("--since", at(500), "--project", "demo")
        # Then
        self.assertEqual(self.sessions(report), {"work"})


if __name__ == "__main__":
    ANALYZER = sys.argv.pop(1)
    unittest.main(verbosity=2)
