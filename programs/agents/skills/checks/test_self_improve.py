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
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import partial
from pathlib import Path

ANALYZER = ""
BASE = datetime(2026, 1, 1, tzinfo=timezone.utc)


def at(seconds: float) -> str:
    return (BASE + timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


@dataclass
class Transcript:
    """Builds one agent's JSONL transcript; times are seconds after BASE."""

    cwd: str = "/home/dev/repos/demo"
    parent: str | None = None  # a subagent's spawning Agent call, as its meta.json names it
    parent_agent: str | None = None  # the subagent that spawned this one, as its meta.json names it
    lines: list[dict] = field(default_factory=list)
    calls: int = 0

    def event(self, t: float, kind: str, **fields: object) -> Transcript:
        self.lines.append({"type": kind, "timestamp": at(t), "cwd": self.cwd, **fields})
        return self

    def human(self, t: float, text: str) -> Transcript:
        return self.event(t, "user", origin={"kind": "human"}, message={"role": "user", "content": text})

    def command(self, t: float, name: str) -> Transcript:
        return self.human(t, f"<command-message>{name}</command-message>\n<command-name>/{name}</command-name>")

    def brief(self, t: float, text: str) -> Transcript:
        """A subagent's prompt: its first user line, typed by no person."""
        return self.event(t, "user", message={"role": "user", "content": text})

    def handback(self, t: float, message: str) -> Transcript:
        self.tool(t, "SubagentHandback", t, message=message)
        return self

    def reply(self, t: float, usage: dict | None = None, skill: str | None = None, content_lines: int = 1,
              text: str = "ok") -> Transcript:
        """One model response, written as Claude Code does: one line per content block."""
        self.calls += 1
        message = {"id": f"msg_{self.calls}", "role": "assistant", "content": [{"type": "text", "text": text}],
                   "usage": usage or {}}
        for _ in range(content_lines):
            self.event(t, "assistant", message=message, attributionSkill=skill)
        return self

    def tool(self, t: float, name: str, done: float, *, result: str | list[dict] = "ok", error: bool = False,
             background: bool = False, **tool_input: object) -> str:
        """A tool call and its result. Returns the tool_use id."""
        self.calls += 1
        use_id = f"toolu_{self.calls}"
        self.tool_use(t, f"msg_{self.calls}", use_id, name, tool_input)
        extra = {"backgroundTaskId": f"bg{self.calls}"} if background else {}
        self.tool_result(done, use_id, result, error, extra)
        return use_id

    def tool_use(self, t: float, response: str, use_id: str, name: str, tool_input: dict) -> None:
        self.event(t, "assistant", message={"id": response, "role": "assistant", "usage": {},
                                            "content": [{"type": "tool_use", "id": use_id, "name": name,
                                                         "input": tool_input}]})

    def tool_result(self, t: float, use_id: str, result: str | list[dict] = "ok", error: bool = False,
                    extra: dict | None = None) -> None:
        self.event(t, "user", toolUseResult=extra or {},
                   message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": use_id,
                                                         "content": result, "is_error": error}]})

    def bash(self, t: float, command: str, done: float, **kw: object) -> str:
        return self.tool(t, "Bash", done, command=command, **kw)

    def siblings(self, *calls: tuple[float, str, dict, float]) -> None:
        """One response of several (streamed at, tool, input, done) calls, written as Claude Code does:
        one line per block, stamped when that block finished streaming, and each result where it landed,
        so a tool finishing mid-stream answers between the lines of its own response."""
        self.calls += 1
        response = f"msg_{self.calls}"
        lines: list[tuple[float, Callable[[], None]]] = []
        for t, name, tool_input, done in calls:
            self.calls += 1
            use_id = f"toolu_{self.calls}"
            lines.append((t, partial(self.tool_use, t, response, use_id, name, tool_input)))
            lines.append((done, partial(self.tool_result, done, use_id)))
        for _, write in sorted(lines, key=lambda line: line[0]):
            write()

    def notify(self, t: float, use_id: str, status: str, summary: str) -> Transcript:
        return self.event(t, "queue-operation", operation="enqueue", content=notification(use_id, status, summary))

    def attach_notification(self, t: float, use_id: str, status: str, summary: str) -> Transcript:
        """How a subagent's transcript carries a task notification."""
        attachment = {"type": "queued_command", "commandMode": "task-notification",
                      "prompt": notification(use_id, status, summary)}
        return self.event(t, "attachment", attachment=attachment)


def notification(use_id: str, status: str, summary: str) -> str:
    return (f"<task-notification>\n<task-id>x</task-id>\n<tool-use-id>{use_id}</tool-use-id>\n"
            f"<status>{status}</status>\n<summary>{summary}</summary>\n</task-notification>")


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
            meta = {"agentType": kind, "description": description, "toolUseId": transcript.parent,
                    "parentAgentId": transcript.parent_agent}
            base.with_suffix(".meta.json").write_text(json.dumps(meta))

    def report(self, *args: str) -> str:
        run = subprocess.run([sys.executable, "-I", ANALYZER, "--root", str(self.root), *args],
                             capture_output=True, text=True, check=True)
        return run.stdout


def worker(description: str, transcript: Transcript) -> tuple[str, str, Transcript]:
    return "general-purpose", description, transcript


def write(path: Path, transcript: Transcript) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(line) + "\n" for line in transcript.lines))


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
        self.home.session("s1", main, {"a1": worker("Implement parser", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Tokens by agent type", "general-purpose")[1:5], ["1", "2", "0/5.0M/50k/0", "3.0M"])
        self.assertEqual(row(report, "Costliest subagents", "s1")[1:5], ["general-purpose", "Implement parser", "0/5.0M/50k/0", "3.0M"])
        self.assertEqual(row(report, "Tokens by skill", "engineering")[1:], ["1", "0/3.0M/0/0"])
        self.assertIn("/engineer", row(report, "Sessions", "s1")[5])


class EffectiveCost(Case):
    USAGE = {"input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 400,
             "output_tokens": 20}  # 10 + 100 + 500 + 100 = 710

    def test_a_call_is_weighed_by_what_it_pays(self) -> None:
        # Given: a main call and a subagent call of the same usage, the subagent's reported twice
        main = Transcript().human(0, "go").reply(1, self.USAGE)
        sub = Transcript().brief(5, "build").reply(6, self.USAGE, content_lines=2).reply(7, self.USAGE)
        self.home.session("s1", main, {"a1": worker("Implement parser", sub)})
        # When
        report = self.home.report()
        # Then: every view sums weighted calls, counting a split response once
        self.assertIn("2k = main 710, subagents 1k", section(report, "Session report"))
        self.assertEqual(row(report, "Sessions", "s1")[-1], "2k")
        self.assertEqual(row(report, "Tokens by agent type", "main")[-1], "710")
        self.assertEqual(row(report, "Tokens by agent type", "general-purpose")[-1], "1k")
        self.assertEqual(row(report, "Costliest subagents", "s1")[-1], "1k")
        self.assertEqual(row(report, "Loop steps", "implement")[-1], "1k")

    def test_output_outranks_cached_context(self) -> None:
        # Given: a large cached subagent and a small one that writes more
        cached = Transcript().brief(5, "a").reply(6, {"cache_read_input_tokens": 100_000})
        verbose = Transcript().brief(5, "b").reply(6, {"output_tokens": 10_000})
        self.home.session("s1", idle_main(), {"a1": worker("Cached", cached), "a2": worker("Verbose", verbose)})
        # When
        lines = section(self.home.report(), "Costliest subagents").splitlines()
        # Then
        self.assertIn("Verbose", next(line for line in lines if "general-purpose" in line))


REWRITE = {"input_tokens": 1000, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 90_000}  # costs 112k


class CacheRewrites(Case):
    def test_a_subagent_rewrite_after_each_wait_is_split_by_that_wait(self) -> None:
        # Given: a subagent that loses its cache behind a foreground Bash, a foreground Agent and no tool
        sub = Transcript().brief(0, "build").reply(1, {"cache_read_input_tokens": 1000})
        sub.bash(2, "just test", 400)
        sub.reply(401, REWRITE)
        sub.tool(402, "Agent", 800, description="Research")
        sub.reply(801, REWRITE)
        sub.reply(1200, REWRITE)
        self.home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Cache rewrites", "foreground Bash")[1:], ["1", "112k"])
        self.assertEqual(row(report, "Cache rewrites", "Agent")[1:], ["1", "112k"])
        self.assertEqual(row(report, "Cache rewrites", "idle")[1:], ["1", "112k"])
        self.assertIn("3 rewrites, 338k effective", section(report, "Cache rewrites"))
        self.assertEqual(row(report, "Cache rewrites", "s1")[1:], ["general-purpose", "Implement parser", "3", "338k"])

    def test_a_gap_within_the_cache_life_is_no_rewrite(self) -> None:
        # Given: a large write under 5 minutes after the previous call
        sub = Transcript().brief(0, "build").reply(1).reply(299, REWRITE)
        self.home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        self.assertIn("0 rewrites", section(self.home.report(), "Cache rewrites"))

    def test_a_small_write_after_a_gap_is_no_rewrite(self) -> None:
        # Given: half the context written after a long gap, the cache having survived the rest
        half = {"cache_read_input_tokens": 50_000, "cache_creation_input_tokens": 50_000}
        sub = Transcript().brief(0, "build").reply(1).reply(1000, half)
        self.home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        self.assertIn("0 rewrites", section(self.home.report(), "Cache rewrites"))

    def test_a_main_agent_keeps_its_cache_for_an_hour(self) -> None:
        # Given: main gaps of 59 and 61 minutes before a large write
        main = Transcript().human(0, "go").reply(1).reply(3541, REWRITE).reply(7202, REWRITE)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then: only the second counts
        self.assertEqual(row(report, "Cache rewrites", "s1")[1:], ["main", "", "1", "112k"])
        self.assertEqual(row(report, "Cache rewrites", "idle")[1:], ["1", "112k"])

    def test_a_background_bash_is_idle(self) -> None:
        # Given: the wait came after a command sent to the background
        sub = Transcript().brief(0, "build")
        sub.bash(1, "just test", 2, background=True)
        sub.reply(400, REWRITE)
        self.home.session("s1", idle_main(), {"a1": worker("Implement parser", sub)})
        # When / Then
        self.assertEqual(row(self.home.report(), "Cache rewrites", "idle")[1:], ["1", "112k"])


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

    def test_sibling_calls_are_timed_from_the_end_of_their_response(self) -> None:
        # Given: a quick mkdir streamed before a Write whose block took 60s to stream
        main = Transcript().human(0, "go")
        main.siblings((40, "Bash", {"command": "mkdir -p /tmp/x"}, 102), (100, "Write", {"file_path": "/tmp/x/a"}, 102))
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then: neither call is charged the 60s of streaming
        self.assertEqual(row(report, "Wall time per Bash command", "mkdir")[5], "2s")
        self.assertEqual(row(report, "Wall time per tool", "Write")[5], "2s")

    def test_a_call_finishing_mid_stream_is_timed_from_its_own_line(self) -> None:
        # Given: a Read answered at 45 while its response streamed on until 100
        main = Transcript().human(0, "go")
        main.siblings((40, "Read", {"file_path": "/a"}, 45), (100, "Write", {"file_path": "/b"}, 102))
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then: the Read keeps its 5s and is not moved past its own result
        self.assertEqual(row(report, "Wall time per tool", "Read")[5], "5s")
        self.assertEqual(row(report, "Wall time per tool", "Write")[5], "2s")

    def test_a_subagent_background_start_is_timed_to_its_notification(self) -> None:
        # Given: a subagent whose transcript has only the result text and an attached notification
        start = "Command running in background with ID: b1. Output is being written to: /tmp/b1.output"
        sub = awaited_subagent()
        bg = sub.bash(10, "just check", 11, result=start)
        sub.attach_notification(310, bg, "completed", 'Background command "check" completed (exit code 0)')
        self.home.session("s1", awaiting_subagent(400), {"s": worker("Implement", sub)})
        # When
        report = self.home.report()
        # Then: one background call of 300s, not a 1s foreground one
        self.assertEqual(row(report, "Wall time per Bash command", "just check")[1:6], ["0", "0m", "1", "5m", "300s"])

    def test_a_subagent_timeout_moved_to_the_background_is_timed_to_its_notification(self) -> None:
        # Given: a foreground call the harness moved to the background at its timeout
        moved = "Command did not complete within its 600s timeout and was moved to the background with ID: b1."
        sub = awaited_subagent()
        bg = sub.bash(10, "just check", 610, result=moved)
        sub.attach_notification(910, bg, "completed", 'Background command "check" completed (exit code 0)')
        self.home.session("s1", awaiting_subagent(1000), {"s": worker("Implement", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Wall time per Bash command", "just check")[1:6], ["0", "0m", "1", "15m", "900s"])

    def test_a_subagent_background_agent_is_timed_to_its_notification(self) -> None:
        # Given: a subagent spawning a background agent, with the result as a text block
        launched = [{"type": "text", "text": "Async agent launched successfully."}]
        sub = awaited_subagent()
        child = sub.tool(10, "Agent", 11, result=launched, description="Research")
        sub.attach_notification(130, child, "completed", "Agent finished")
        self.home.session("s1", awaiting_subagent(50), {"s": worker("Implement", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Wall time per tool", "Agent")[1:3], ["bg", "1"])
        self.assertEqual(row(report, "Wall time per tool", "Agent")[4:], ["120s", "120s"])

    def test_a_subagent_background_failure_is_a_failure(self) -> None:
        # Given: a background command failing in a subagent's attached notification
        sub = awaited_subagent()
        bg = sub.bash(10, "just check", 11, result="Command running in background with ID: b1.")
        sub.attach_notification(100, bg, "failed", 'Background command "check" failed with exit code 2')
        self.home.session("s1", awaiting_subagent(200), {"s": worker("Implement", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Wall time per Bash command", "just check")[6], "1")

    def test_output_quoting_a_background_start_stays_a_foreground_call(self) -> None:
        # Given: a foreground command that prints the words mid-output
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 20, result="note: Command running in background with ID: b1.")
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Wall time per Bash command", "just check")[1:3], ["1", "0m"])

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
        # And: the question is not ranked as a tool bottleneck
        self.assertNotIn("| AskUserQuestion |", section(report, "Wall time per tool"))

    def test_a_human_gap_with_background_work_running_is_work(self) -> None:
        # Given: a background agent works 20 min into a 30 min silence in the main transcript,
        # and its notification is not in it, so only the subagent's own calls show the work
        main = Transcript().human(0, "go")
        spawn = main.tool(60, "Agent", 61, background=True, description="Review")
        main.human(1860, "next").reply(3600)
        sub = Transcript(parent=spawn)
        sub.bash(61, "just check", 1260)
        self.home.session("s1", main, {"a1": worker("Review", sub)})
        # When
        report = self.home.report()
        # Then: only the 10 idle minutes after the subagent's work are waiting
        self.assertEqual(row(report, "Sessions", "s1")[3:5], ["60m", "10m"])


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
        self.home.session("s1", main, {"a1": worker("Implement", sub)})
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

    def test_an_edit_sent_before_a_check_in_one_response_is_a_change(self) -> None:
        # Given: an Edit and a rerun of a check, sibling calls of one response
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 70)
        main.siblings((80, "Edit", {"file_path": "/repo/src/Main.hs"}, 91), (90, "Bash", {"command": "just check"}, 150))
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 0, 0m.", report)

    def test_an_edit_sent_after_a_check_in_one_response_is_a_change_for_the_next_run(self) -> None:
        # Given: a check and an Edit, sibling calls of one response, then the check again
        main = Transcript().human(0, "go")
        main.siblings((80, "Bash", {"command": "just check"}, 150), (90, "Edit", {"file_path": "/repo/src/Main.hs"}, 151))
        main.bash(160, "just check", 220)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 0, 0m.", report)

    def test_an_edit_sent_before_a_full_check_in_one_response_keeps_the_test_out_of_the_chain(self) -> None:
        # Given: a test step, then an Edit and a full check, sibling calls of one response
        main = Transcript().human(0, "go")
        main.bash(10, "nix run .#test", 70)
        main.siblings((80, "Edit", {"file_path": "/repo/src/Main.hs"}, 91), (90, "Bash", {"command": "just check"}, 150))
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Build/test steps run before a full check with no edit between: 0, 0m.", report)

    def test_an_edit_sent_after_a_test_in_one_response_keeps_the_test_out_of_the_chain(self) -> None:
        # Given: a test step and an Edit, sibling calls of one response, then a full check
        main = Transcript().human(0, "go")
        main.siblings((80, "Bash", {"command": "nix run .#test"}, 150), (90, "Edit", {"file_path": "/repo/src/Main.hs"}, 151))
        main.bash(160, "just check", 220)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Build/test steps run before a full check with no edit between: 0, 0m.", report)

    def test_a_sibling_of_a_check_that_changes_nothing_leaves_it_a_rerun(self) -> None:
        # Given: a Read beside a rerun of a check
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 70)
        main.siblings((80, "Read", {"file_path": "/repo/src/Main.hs"}, 91), (90, "Bash", {"command": "just check"}, 150))
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 1, 1m.", report)

    def test_a_python_heredoc_writing_a_file_counts_as_a_change(self) -> None:
        # Given: three edits made by a Python heredoc, each between two runs of a check
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 70)
        main.bash(80, "python3 - <<'EOF'\nfrom pathlib import Path\nPath('a.py').write_text('x')\nEOF", 81)
        main.bash(90, "just check", 150)
        main.bash(160, "python3 -I - <<EOF\nwith open('a.py', 'w') as f:\n    f.write('y')\nEOF", 161)
        main.bash(170, "just check", 230)
        main.bash(240, "python3 - <<'EOF'\nfrom pathlib import Path\nPath('a.py').open('w').write('z')\nEOF", 241)
        main.bash(250, "just check", 310)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 0, 0m.", report)

    def test_a_python_heredoc_that_only_reads_is_no_change(self) -> None:
        # Given: two heredocs reading a file, each between two runs of a check
        main = Transcript().human(0, "go")
        main.bash(10, "just check", 70)
        main.bash(80, "python3 - <<'EOF'\nprint(open('data.txt').read())\nEOF", 81)
        main.bash(90, "just check", 150)
        main.bash(160, "python3 - <<'EOF'\nfrom pathlib import Path\nprint(Path('a.txt').open('r').read())\nEOF", 161)
        main.bash(170, "just check", 230)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertIn("Reruns with nothing changed since the same check: 2, 2m.", report)


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


def subagent(brief: str, usage: dict | None = None, parent_agent: str | None = None) -> Transcript:
    return Transcript(parent_agent=parent_agent).brief(5, brief).reply(6, usage)


def idle_main() -> Transcript:
    return Transcript().human(0, "go").reply(1)


def awaiting_subagent(done: float) -> Transcript:
    """A session whose first tool call runs `awaited_subagent` in the foreground until `done`."""
    main = Transcript().human(0, "go")
    main.tool(1, "Agent", done, description="Implement")
    return main


def awaited_subagent() -> Transcript:
    return Transcript(parent="toolu_1").brief(0, "Implement")


def spawning_implementer() -> Transcript:
    main = Transcript().human(0, "go")
    main.tool(1, "Agent", 2, background=True, description="Implement parser")
    return main


class LoopSteps(Case):
    def test_each_subagent_lands_in_its_step(self) -> None:
        # Given: one subagent per step, named as the loop names them
        main = Transcript().human(0, "go").reply(1, {"cache_read_input_tokens": 1000})
        self.home.session("s1", main, {
            "a": worker("Research the parser", subagent("look around")),
            "b": worker("Implement parser", subagent("build it")),
            "c": worker("Refactor branch", subagent("invoke `refactor` on the branch")),
            "d": worker("Review", subagent(REVIEW_BRIEF)),
            "e": worker("Review", subagent(REVIEW_BRIEF + " --fixes abc123")),
            "f": worker("Final review", subagent(REVIEW_BRIEF)),
            "g": worker("Fix rows 1 and 2", subagent("fix them, then invoke `pragmatic-review` never")),
            "h": worker("Write PR description", subagent("describe it")),
            "i": worker("Sweep the floor", subagent("something else")),
        })
        # When
        report = self.home.report()
        # Then
        for step in ("orchestrator", "research", "implement", "refactor", "review 1", "review 2", "final review",
                     "fix", "pr description", "other"):
            self.assertEqual(row(report, "Loop steps", step)[1:3], ["1", "1"], step)

    def test_a_child_counts_under_its_parents_step_with_its_tokens_and_wall(self) -> None:
        # Given: a review agent and the agent it spawned, 10 minutes each
        parent = subagent(REVIEW_BRIEF, {"cache_read_input_tokens": 2000}).reply(605)
        child = subagent("the bar", {"cache_read_input_tokens": 1000}, parent_agent="r").reply(605)
        self.home.session("s1", idle_main(),
                          {"r": worker("Review", parent), "c": worker("Blockers", child)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Loop steps", "review 1")[1:5], ["2", "1", "0/3k/0/0", "20m"])


class ReviewYield(Case):
    def report_with_review(self, sub: Transcript) -> str:
        self.home.session("s1", idle_main(), {"r": worker("Review", sub)})
        return self.home.report()

    def test_a_report_handed_back_is_counted_in_its_pass(self) -> None:
        # Given: a first review whose hand-back carries the fixed report format
        sub = subagent(REVIEW_BRIEF, {"cache_read_input_tokens": 5000}).handback(7, REVIEW_REPORT)
        # When
        report = self.report_with_review(sub)
        # Then: reports, tokens, raised, survived, severities, verdicts, do not merge, unparsed
        self.assertEqual(row(report, "Review yield", "review 1")[1:],
                         ["1", "0/5k/0/0", "3", "2", "1", "1", "0", "1", "1", "1", "1", "0"])

    def test_a_second_pass_is_a_row_of_its_own(self) -> None:
        # Given
        sub = subagent(REVIEW_BRIEF + " --fixes abc123").handback(7, "Ready to merge - nothing serious. 4 raised, 0 survived.")
        # When
        report = self.report_with_review(sub)
        # Then
        self.assertEqual(row(report, "Review yield", "review 2")[3:5], ["4", "0"])
        self.assertNotIn("| review 1 |", section(report, "Review yield"))

    def test_an_agent_with_no_hand_back_is_read_from_its_last_text(self) -> None:
        # Given: the report is the agent's last text, with no SubagentHandback call
        sub = subagent(REVIEW_BRIEF).reply(7, text=REVIEW_REPORT)
        # When
        report = self.report_with_review(sub)
        # Then
        self.assertEqual(row(report, "Review yield", "review 1")[3:5], ["3", "2"])

    def test_a_report_without_the_verdict_arithmetic_counts_as_unparsed(self) -> None:
        # Given
        sub = subagent(REVIEW_BRIEF).handback(7, "Looks fine to me.")
        # When
        report = self.report_with_review(sub)
        # Then
        cells = row(report, "Review yield", "review 1")
        self.assertEqual((cells[1], cells[3], cells[-1]), ("1", "0", "1"))

    def test_a_review_the_main_agent_ran_has_a_row_without_tokens(self) -> None:
        # Given
        main = Transcript().human(0, "go").reply(1, {"cache_read_input_tokens": 9000}, text=REVIEW_REPORT)
        self.home.session("s1", main)
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Review yield", "run by main")[1:5], ["1", "-", "3", "2"])

    def test_a_review_seconds_budget_is_not_a_second_pass(self) -> None:
        # Given: a first review whose brief mentions seconds
        sub = subagent(REVIEW_BRIEF + ", 30 seconds per file").handback(7, REVIEW_REPORT)
        # When
        report = self.report_with_review(sub)
        # Then
        self.assertEqual(row(report, "Review yield", "review 1")[1], "1")

    def test_a_hand_back_wins_over_text_written_after_it(self) -> None:
        # Given: the last hand-back is the report, and text follows it
        sub = subagent(REVIEW_BRIEF).handback(7, "1 raised, 1 survived.").handback(8, REVIEW_REPORT)
        sub.reply(9, text="Handed back.")
        # When
        report = self.report_with_review(sub)
        # Then
        self.assertEqual(row(report, "Review yield", "review 1")[3:5], ["3", "2"])

    def test_a_review_agent_with_no_recorded_usage_still_shows_its_tokens(self) -> None:
        # Given: a review agent whose transcript recorded no usage
        sub = subagent(REVIEW_BRIEF).handback(7, REVIEW_REPORT)
        # When
        report = self.report_with_review(sub)
        # Then: zero tokens, not the "-" of a review with none to attribute
        self.assertEqual(row(report, "Review yield", "review 1")[2], "0/0/0/0")

    def test_a_main_agent_report_without_the_arithmetic_keeps_its_rows_and_counts_as_unparsed(self) -> None:
        # Given: a report the main agent wrote, its verdict line drifted
        text = REVIEW_REPORT.replace(" 3 raised, 2 survived.", "")
        self.home.session("s1", Transcript().human(0, "go").reply(1, text=text))
        # When
        cells = row(self.home.report(), "Review yield", "run by main")
        # Then: reports, tokens, raised, survived, major, minor, then unparsed last
        self.assertEqual(cells[1:7], ["1", "-", "0", "0", "1", "1"])
        self.assertEqual(cells[-1], "1")

    def test_main_agent_text_without_rows_or_arithmetic_is_no_report(self) -> None:
        # Given
        self.home.session("s1", Transcript().human(0, "go").reply(1, text="Major refactor done | see the PR"))
        # When / Then
        self.assertNotIn("run by main", section(self.home.report(), "Review yield"))

    def test_a_review_under_an_orchestrator_subagent_is_counted_with_its_own_tree(self) -> None:
        # Given: an orchestrator subagent, the review it spawned, and that review's tests agent
        finding = "a.py:1\nseverity    major\nclaim       invented\n"
        self.home.session("s1", idle_main(), {
            "o": worker("Run the loop", subagent("drive the loop", {"cache_read_input_tokens": 9000})),
            "r": worker("Review", subagent(REVIEW_BRIEF, {"cache_read_input_tokens": 2000}, parent_agent="o")
                        .handback(7, REVIEW_REPORT)),
            "t": worker("Tests agent", subagent("the bar", {"cache_read_input_tokens": 1000}, parent_agent="r")
                        .handback(7, finding)),
        })
        # When
        report = self.home.report()
        # Then: the review and its child, without the orchestrator's tokens
        self.assertEqual(row(report, "Review yield", "review 1")[1:7], ["1", "0/3k/0/0", "3", "2", "1", "1"])
        self.assertEqual(row(report, "Loop steps", "review 1")[1], "2")
        self.assertEqual(row(report, "Review yield", "tests")[1], "1")

    def test_inner_agents_are_counted_by_type(self) -> None:
        # Given: a review agent, its tests agent with a finding, its requirement agent with a verdict,
        # and its blockers agent finding nothing
        finding = "a.py:1\nseverity    major\nclaim       invented\n"
        verdict = "requirement  invented\nverdict      unverified\nexamined     nothing\n"
        self.home.session("s1", idle_main(), {
            "r": worker("Review", subagent(REVIEW_BRIEF).handback(7, REVIEW_REPORT)),
            "t": worker("Tests agent", subagent("the bar", parent_agent="r").handback(7, finding)),
            "q": worker("Requirement 1", subagent("the bar", parent_agent="r").handback(7, verdict)),
            "b": worker("Blockers", subagent("the bar", parent_agent="r").handback(7, "NONE")),
        })
        # When
        report = self.home.report()
        # Then: runs, major, minor, nit, runs with a finding, not met, unverified
        cells = lambda name: [row(report, "Review yield", name)[i] for i in (1, 3, 4, 5, 6, 7, 8)]
        self.assertEqual(cells("tests"), ["1", "1", "0", "0", "1", "0", "0"])
        self.assertEqual(cells("requirement"), ["1", "0", "0", "0", "0", "0", "1"])
        self.assertEqual(cells("blockers"), ["1", "0", "0", "0", "0", "0", "0"])


class AfterHandback(Case):
    def test_only_prompts_after_the_first_gh_pr_ready_count(self) -> None:
        # Given: a prompt before the first `gh pr ready`, then free text and two commands
        # after it, a second ready among them
        main = Transcript().human(0, "go").human(5, "also this")
        main.bash(10, "gh pr ready 1", 11)
        main.human(20, "why this?")
        main.bash(25, "gh pr ready 1", 26)
        main.command(30, "final-review").command(40, "give-feedback").reply(50)
        self.home.session("s1", main)
        self.home.session("s2", Transcript().human(0, "no ready here").human(5, "more").reply(6))
        # When
        report = self.home.report()
        # Then
        self.assertIn("Sessions that ran `gh pr ready`: 1, with a human prompt after it: 1", report)
        self.assertIn("Human prompts after it: 3: 1 free text, /final-review 1, /give-feedback 1", report)

    def test_a_ready_run_by_a_subagent_counts(self) -> None:
        # Given
        main = Transcript().human(0, "go").human(100, "looks wrong").reply(101)
        sub = subagent("finish it")
        sub.bash(50, "gh pr ready 1", 51)
        self.home.session("s1", main, {"a": worker("Finish", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertIn("Human prompts after it: 1: 1 free text", report)


class Communication(Case):
    def two_agents_run(self, *commands: str) -> None:
        first, second = subagent("look"), subagent("look")
        for t, command in enumerate(commands):
            first.bash(7 + t, command, 8 + t, result="x" * 1000)
            second.bash(7 + t, command, 8 + t, result="x" * 1000)
        self.home.session("s1", idle_main(), {"a": worker("Audit a", first), "b": worker("Audit b", second)})

    def test_brief_and_hand_back_sizes_are_reported_by_type_and_step(self) -> None:
        # Given: two implementers, one over the hand-back limit, one too thin
        self.home.session("s1", idle_main(), {
            "a": worker("Implement a", subagent("word " * 100).handback(7, "word " * 400)),
            "b": worker("Implement b", subagent("word " * 200).handback(7, "done")),
        })
        # When
        report = self.home.report()
        # Then: agents, median and max brief, median and max hand-back, over the limit, under the floor
        self.assertEqual(row(report, "Agent communication", "general-purpose")[1:],
                         ["implement", "2", "150", "200", "200", "400", "1", "1"])

    def test_a_large_hand_back_is_priced_by_the_parent_calls_after_it(self) -> None:
        # Given: a 400-word hand-back at 7s and two parent calls after it, one before
        main = Transcript().human(0, "go")
        main.tool(1, "Agent", 2, background=True, description="Research x")
        main.bash(20, "true", 21)
        main.bash(30, "true", 31)
        sub = subagent("look").handback(7, "word " * 400)
        self.home.session("s1", main, {"a": worker("Research x", sub)})
        # When
        report = self.home.report()
        # Then: 2000 chars is 500 tokens, sent twice more
        self.assertIn("Hand-backs over 300 words: 1, 2k chars, about 1k tokens sent again", report)

    def test_a_hand_back_pointing_at_a_notes_file_is_counted(self) -> None:
        # Given
        sub = subagent("look").handback(7, "Ranked index in /tmp/topic/notes.md, top item first.")
        self.home.session("s1", idle_main(), {"a": worker("Research x", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertIn("Hand-backs pointing at a notes file: 1", report)

    def test_a_follow_up_message_to_a_subagent_is_counted(self) -> None:
        # Given
        main = Transcript().human(0, "go")
        main.tool(1, "SendMessage", 2, to="a", message="you also need x")
        self.home.session("s1", main, {"a": worker("Research x", subagent("look"))})
        # When
        report = self.home.report()
        # Then
        self.assertIn("Follow-up messages to a subagent: 1", report)

    def report_with_implementer(self, main: Transcript, *others: Transcript) -> str:
        """The report of `main` and an implementer that hands back at 7s, naming `parser.py`."""
        implementer = subagent("build it").handback(7, "Changed src/parser.py, tests pass.")
        agents = {"a": worker("Implement parser", implementer)}
        self.home.session("s1", main, agents | {f"b{i}": worker("Refactor branch", t) for i, t in enumerate(others)})
        return self.home.report()

    def test_a_parent_rereading_a_named_file_or_a_diff_is_a_re_read(self) -> None:
        # Given: the parent reads the named file, an unnamed file, and a diff
        main = spawning_implementer()
        main.tool(10, "Read", 11, file_path="/repo/src/parser.py", result="x" * 500)
        main.tool(12, "Read", 13, file_path="/repo/src/other.py", result="x" * 500)
        main.bash(90, "git diff HEAD~1", 91, result="y" * 300)
        # When
        report = self.report_with_implementer(main)
        # Then: hand-backs, re-reads, re-read chars
        self.assertEqual(row(report, "Agent communication", "implement")[1:4], ["1", "2", "800"])

    def test_a_diff_of_another_worktree_is_a_re_read(self) -> None:
        # Given: the parent diffs a path it named with `git -C`
        main = spawning_implementer()
        main.bash(90, "git -C /repo/worktree diff HEAD~1", 91, result="y" * 300)
        # When
        report = self.report_with_implementer(main)
        # Then: hand-backs, re-reads, re-read chars
        self.assertEqual(row(report, "Agent communication", "implement")[1:4], ["1", "1", "300"])

    def test_a_parent_rerunning_a_check_is_a_re_verify(self) -> None:
        # Given
        main = spawning_implementer()
        main.bash(20, "just check", 80)
        # When
        report = self.report_with_implementer(main)
        # Then: re-verifies, re-verify time
        self.assertEqual(row(report, "Agent communication", "implement")[4:6], ["1", "1m"])

    def test_a_read_after_the_next_spawn_answers_no_hand_back(self) -> None:
        # Given: the named file is read after a later spawn that is still running
        main = spawning_implementer()
        main.tool(100, "Agent", 101, background=True, description="Refactor branch")
        main.tool(120, "Read", 121, file_path="/repo/src/parser.py", result="x" * 500)
        refactorer = Transcript().brief(110, "invoke `refactor`").reply(111).handback(200, "Nothing to change.")
        # When
        report = self.report_with_implementer(main, refactorer)
        # Then
        self.assertEqual(row(report, "Agent communication", "implement")[1:6], ["1", "0", "0", "0", "0m"])
        self.assertEqual(row(report, "Agent communication", "refactor")[1:6], ["1", "0", "0", "0", "0m"])

    def test_a_spawn_repeating_the_step_after_its_hand_back_is_counted_but_parallel_ones_are_not(self) -> None:
        # Given: two research agents in parallel, then a third after both returned
        def research(start: float, end: float) -> Transcript:
            return Transcript().brief(start, "look").reply(end)
        self.home.session("s1", idle_main(), {
            "a": worker("Research a", research(5, 50)),
            "b": worker("Research b", research(6, 60)),
            "c": worker("Research c", research(70, 80)),
        })
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Agent communication", "research")[-1], "1")

    def test_the_same_read_by_two_agents_is_repeated_work(self) -> None:
        # Given: two agents read one file; the first also reads a file nobody else does
        first = subagent("look")
        first.tool(7, "Read", 8, file_path="/repo/big.py", result="x" * 1000)
        first.tool(9, "Read", 10, file_path="/repo/own.py", result="x" * 1000)
        second = subagent("look")
        second.tool(7, "Read", 8, file_path="/repo/big.py", result="x" * 1000)
        self.home.session("s1", idle_main(), {
            "a": worker("Audit a", first), "b": worker("Audit b", second)})
        # When
        report = self.home.report()
        # Then
        self.assertIn("by two or more agents of a session: 1, 1k chars repeated.", report)
        self.assertEqual(row(report, "Agent communication", "s1")[1:], ["/repo/big.py", "2", "2", "1k"])

    def test_the_same_read_by_the_main_agent_and_a_subagent_is_repeated_work(self) -> None:
        # Given
        main = Transcript().human(0, "go")
        main.tool(1, "Read", 2, file_path="/repo/big.py", result="x" * 1000)
        sub = subagent("look")
        sub.tool(7, "Read", 8, file_path="/repo/big.py", result="x" * 1000)
        self.home.session("s1", main, {"a": worker("Audit a", sub)})
        # When
        report = self.home.report()
        # Then
        self.assertEqual(row(report, "Agent communication", "s1")[1:], ["/repo/big.py", "2", "2", "1k"])

    def test_a_read_command_run_by_two_agents_is_repeated_work_in_any_form(self) -> None:
        # Given: two agents running one read command, chained, then through `git -C`
        self.two_agents_run("cd /repo && sed -n 1,40p big.py 2>/dev/null | head -5 || true", "git -C /repo log -1")
        # When
        report = self.home.report()
        # Then
        self.assertIn("by two or more agents of a session: 2, 2k chars repeated.", report)

    def test_a_command_outside_the_read_list_is_no_repeated_read(self) -> None:
        # Given: two agents running the same commands, none of them a read
        self.two_agents_run("git push -u origin HEAD", "rm -f /repo/big.py", "rg foo /repo > /tmp/hits", "cd /repo")
        # When
        report = self.home.report()
        # Then
        self.assertIn("by two or more agents of a session: 0, 0 chars repeated.", report)

    def test_an_implementer_rereading_what_research_read_is_a_split(self) -> None:
        # Given: research reads two files, then an implementer reads one of them through
        # Bash, and an earlier implementer reads the other before research finished
        research = Transcript().brief(50, "look").reply(51)
        research.tool(52, "Read", 53, file_path="/repo/a.py")
        research.tool(54, "Read", 55, file_path="/repo/b.py")
        late = Transcript().brief(100, "build").reply(101)
        late.bash(102, "sed -n 1,40p /repo/a.py", 103)
        early = Transcript().brief(5, "build").reply(6)
        early.tool(7, "Read", 8, file_path="/repo/b.py")
        self.home.session("s1", idle_main(), {
            "r": worker("Research parser", research),
            "l": worker("Implement late", late),
            "e": worker("Implement early", early),
        })
        # When
        report = self.home.report()
        # Then
        self.assertIn("Implementers reading files a research agent read: 1, 1 files between them", report)


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
