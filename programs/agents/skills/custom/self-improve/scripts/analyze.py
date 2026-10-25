#!/usr/bin/env python3
"""Measure where Claude Code sessions spend tokens and wall time.

Reads the transcripts under ~/.claude/projects and prints a compact markdown
report for an agent to read. Standard library only.

Usage: analyze.py [--since ISO] [--project SUBSTR] [--root DIR]

Without --since the window starts at the most recent previous session that
invoked /self-improve, or covers everything when there is none. The latest
/self-improve session is the one running this script and is never reported.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, Union

TOP = 10


def main() -> None:
    args = parse_args()
    sessions = load_sessions(args.root)
    window = select_window(sessions, args.since, args.project)
    print(render(window, describe_window(window.since, args.project)))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", type=lambda v: parse_iso(v).astimezone(timezone.utc), help="ISO date or time; default: the previous /self-improve run")
    parser.add_argument("--project", help="only sessions whose working directory contains this")
    parser.add_argument("--root", type=Path, default=Path.home() / ".claude" / "projects", help=argparse.SUPPRESS)
    return parser.parse_args()


# --- Domain ------------------------------------------------------------------


@dataclass(frozen=True)
class Usage:
    input: int = 0
    cache_read: int = 0
    cache_creation: int = 0
    output: int = 0

    @property
    def context(self) -> int:
        """Tokens sent to the model in one call: the context at that call."""
        return self.input + self.cache_read + self.cache_creation

    def __add__(self, other: Usage) -> Usage:
        return Usage(
            self.input + other.input,
            self.cache_read + other.cache_read,
            self.cache_creation + other.cache_creation,
            self.output + other.output,
        )


def total(usages: Iterable[Usage]) -> Usage:
    return sum(usages, Usage())


@dataclass(frozen=True)
class Response:
    """One model call, deduplicated across the content-block lines it spans."""

    usage: Usage
    skill: str | None


@dataclass(frozen=True)
class Foreground:
    end: float


@dataclass(frozen=True)
class Background:
    end: float | None  # None: still running when the transcript ends


@dataclass(frozen=True)
class Unanswered:
    """A tool call whose result never reached the transcript."""


Timing = Union[Foreground, Background, Unanswered]


@dataclass(frozen=True)
class Ok:
    pass


@dataclass(frozen=True)
class Failed:
    exit_code: int | None
    signature: str


Outcome = Union[Ok, Failed]


@dataclass
class ToolCall:
    id: str
    name: str
    input: dict
    start: float
    timing: Timing = Unanswered()
    outcome: Outcome = Ok()
    result_chars: int = 0
    images: int = 0

    @property
    def command(self) -> str:
        return str(self.input.get("command") or "")

    @property
    def seconds(self) -> float | None:
        match self.timing:
            case Foreground(end) | Background(float() as end):
                return end - self.start
            case _:
                return None

    @property
    def mode(self) -> str:
        return "bg" if isinstance(self.timing, Background) else "fg"


@dataclass
class Agent:
    kind: str  # "main" or the subagent's agentType
    description: str
    responses: list[Response]
    calls: list[ToolCall]

    @property
    def usage(self) -> Usage:
        return total(r.usage for r in self.responses)

    @property
    def peak_context(self) -> int:
        return max((r.usage.context for r in self.responses), default=0)


@dataclass
class Session:
    id: str
    project: str
    cwd: str
    start: float
    end: float
    commands: list[str]
    human_wait: float  # seconds the session sat waiting on the person
    main: Agent
    subagents: list[Agent]

    @property
    def agents(self) -> list[Agent]:
        return [self.main, *self.subagents]

    @property
    def wall(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class Window:
    since: float | None
    sessions: list[Session]


# --- Loading -----------------------------------------------------------------


@dataclass
class Transcript:
    agent: Agent
    times: list[float] = field(default_factory=list)
    commands: list[str] = field(default_factory=list)
    human_wait: float = 0.0
    cwd: str = ""


COMMAND_NAME = re.compile(r"<command-name>/?([\w:-]+)</command-name>")
NOTIFICATION = re.compile(r"<task-notification>(.*?)(?:</task-notification>|$)", re.S)
EXIT_CODE = re.compile(r"exit code (\d+)", re.I)


def load_sessions(root: Path) -> list[Session]:
    sessions = [load_session(path) for path in sorted(root.glob("*/*.jsonl"))]
    return [s for s in sessions if s is not None]


def load_session(path: Path) -> Session | None:
    main = parse_transcript(path, "main", "")
    subs = [parse_subagent(p) for p in sorted(path.with_suffix("").glob("subagents/agent-*.jsonl"))]
    times = main.times + [t for s in subs for t in s.times]
    if not times:
        return None
    return Session(
        id=path.stem,
        project=project_name(main.cwd),
        cwd=main.cwd,
        start=min(times),
        end=max(times),
        commands=main.commands,
        human_wait=main.human_wait + sum(ask_seconds(main.agent)),
        main=main.agent,
        subagents=[s.agent for s in subs],
    )


def parse_subagent(path: Path) -> Transcript:
    meta_path = path.with_name(path.stem + ".meta.json")
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    return parse_transcript(path, meta.get("agentType", "unknown"), meta.get("description", ""))


def project_name(cwd: str) -> str:
    """The repository or directory a session ran in, without its worktree suffix."""
    return Path(cwd.split("/.claude/worktrees/")[0]).name or "?"


def ask_seconds(agent: Agent) -> Iterator[float]:
    for call in agent.calls:
        if call.name == "AskUserQuestion" and call.seconds is not None:
            yield call.seconds


def parse_transcript(path: Path, kind: str, description: str) -> Transcript:
    out = Transcript(Agent(kind, description, [], []))
    responses: dict[str, Response] = {}
    calls: dict[str, ToolCall] = {}
    previous: float | None = None
    for event in read_jsonl(path):
        ts = parse_time(event.get("timestamp"))
        if ts is None:
            continue
        out.cwd = out.cwd or event.get("cwd", "")
        message = event.get("message") or {}
        content = message.get("content")
        match event.get("type"):
            case "assistant":
                key = message.get("id") or event.get("requestId") or f"line-{len(responses)}"
                responses[key] = Response(to_usage(message.get("usage") or {}), event.get("attributionSkill"))
                for block in blocks(content):
                    if block.get("type") == "tool_use":
                        calls[block["id"]] = ToolCall(block["id"], block.get("name", "?"), block.get("input") or {}, ts)
            case "user" if is_tool_results(content):
                for block in blocks(content):
                    if block.get("type") == "tool_result" and block.get("tool_use_id") in calls:
                        record_result(calls[block["tool_use_id"]], block, event.get("toolUseResult"), ts)
            case "user":
                text = plain_text(content)
                out.commands += COMMAND_NAME.findall(text)
                if (event.get("origin") or {}).get("kind") == "human" and previous is not None:
                    out.human_wait += ts - previous
                record_notifications(calls, text, ts)
            case "queue-operation":
                record_notifications(calls, str(event.get("content") or ""), ts)
        out.times.append(ts)
        previous = ts
    out.agent.responses = list(responses.values())
    out.agent.calls = sorted(calls.values(), key=lambda c: c.start)
    return out


def read_jsonl(path: Path) -> Iterator[dict]:
    with path.open(errors="replace") as lines:
        for line in lines:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                yield event


def parse_time(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    return parse_iso(value).timestamp()


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def to_usage(raw: dict) -> Usage:
    return Usage(
        raw.get("input_tokens") or 0,
        raw.get("cache_read_input_tokens") or 0,
        raw.get("cache_creation_input_tokens") or 0,
        raw.get("output_tokens") or 0,
    )


def blocks(content: object) -> list[dict]:
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def is_tool_results(content: object) -> bool:
    return any(b.get("type") == "tool_result" for b in blocks(content))


def plain_text(content: object) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(str(b.get("text", "")) for b in blocks(content))


def record_result(call: ToolCall, block: dict, extra: object, ts: float) -> None:
    text, images = result_text(block.get("content"))
    call.result_chars, call.images = len(text), images
    background = isinstance(extra, dict) and bool(extra.get("backgroundTaskId") or extra.get("isAsync"))
    call.timing = Background(None) if background else Foreground(ts)
    if block.get("is_error"):
        call.outcome = Failed(exit_code(text), signature(text))
    elif "command not found" in text:
        call.outcome = Failed(None, signature(text))


def result_text(content: object) -> tuple[str, int]:
    if isinstance(content, str):
        return content, 0
    items = blocks(content)
    text = "\n".join(str(b.get("text", "")) for b in items if b.get("type") == "text")
    return text, sum(1 for b in items if b.get("type") == "image")


def record_notifications(calls: dict[str, ToolCall], text: str, ts: float) -> None:
    """A background call ends at its first task notification."""
    for body in NOTIFICATION.findall(text):
        call = calls.get(tag(body, "tool-use-id"))
        if call is None or call.timing != Background(None):
            continue
        call.timing = Background(ts)
        if tag(body, "status") == "failed":
            summary = tag(body, "summary")
            call.outcome = Failed(exit_code(summary), clip(summary, 100))


def tag(body: str, name: str) -> str:
    found = re.search(rf"<{name}>(.*?)</{name}>", body, re.S)
    return found.group(1) if found else ""


def exit_code(text: str) -> int | None:
    found = EXIT_CODE.search(text)
    return int(found.group(1)) if found else None


ERROR_LINE = re.compile(r"error|not found|no such file|fatal|denied|failed|traceback|timed out|blocked|refused", re.I)


def signature(text: str) -> str:
    """The error line that identifies a failure, with volatile parts masked."""
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.lower().startswith("exit code")]
    line = next((l for l in lines if ERROR_LINE.search(l)), lines[0] if lines else "")
    line = re.sub(r"/nix/store/[a-z0-9]{32}-", "/nix/store/…-", line)
    line = re.sub(r"\b[0-9a-f]{7,}\b", "…", line)
    return clip(re.sub(r"(?<![A-Za-z])\d+", "N", line), 100)


# --- Window ------------------------------------------------------------------


def select_window(sessions: list[Session], since: datetime | None, project: str | None) -> Window:
    runs = sorted((s for s in sessions if "self-improve" in s.commands), key=lambda s: s.start)
    current = runs[-1].id if runs else None
    start = since.timestamp() if since else (runs[-2].start if len(runs) > 1 else None)
    chosen = [
        s
        for s in sessions
        if s.id != current and (start is None or s.start >= start) and (project is None or project in s.cwd)
    ]
    return Window(start, sorted(chosen, key=lambda s: s.start))


def describe_window(since: float | None, project: str | None) -> str:
    scope = f"since {fmt_time(since)}" if since is not None else "all transcripts"
    return scope + (f", project matching `{project}`" if project else "")


# --- Bash commands -----------------------------------------------------------


@dataclass(frozen=True)
class Step:
    """One simple command inside a Bash call."""

    name: str  # the tool and its subcommand, e.g. "nix run .#test"
    text: str  # the full command without wrappers and redirects


SUBCOMMANDS = {"just": 1, "nix": 2, "git": 1, "gh": 2, "cabal": 1, "npm": 2, "pnpm": 2, "cargo": 1, "systemctl": 1}
WRAPPERS = {"env", "time", "nice", "timeout", "sudo", "exec", "command"}
NOT_A_COMMAND = {"cd", "export", "set", "source", "."}
PLUMBING = {
    "echo", "printf", "tail", "head", "grep", "rg", "sort", "uniq", "wc", "cut", "tr", "jq", "awk", "sed", "tee",
    "xargs", "true", "false", "sleep", "for", "while", "until", "do", "done", "if", "then", "else", "fi",
}
SEGMENT = re.compile(r"&&|\|\||;|\||\n")
REDIRECT = re.compile(r"^\d*(>>?|<)&?\S*$")
FULL_CHECK = re.compile(r"^(just check|nix flake check)$")
STEP = re.compile(
    r"^(just (build|test|lint|fmt|typecheck)|nix build|nix build \.#\S+|nix run \.#(build|test|lint|check)"
    r"|cabal (build|test)|npm (test|run)|pnpm (test|run)|cargo (build|test|clippy))$"
)
CODE_CHANGING_BASH = re.compile(
    r"sed -i|\btee\b|\bcat\s*>|git (pull|merge|rebase|reset|checkout|switch|cherry-pick|am|apply|stash)\b"
)
SLEEP_LOOP = re.compile(r"\bsleep\s+\d|\buntil\b|\bwhile\b.*\bsleep\b", re.S)
PR_CHECKS = re.compile(r"\bgh pr checks\b")
MISSING_TOOL = re.compile(r"([\w.+-]+): (?:command )?not found\b")


def label(command: str) -> str:
    """What a Bash call is, for grouping: its checks, else its main command."""
    found = steps(command)
    checks = [s.name for s in found if is_check(s)]
    if checks:
        return " && ".join(dict.fromkeys(checks))
    if SLEEP_LOOP.search(command):
        return "(sleep/poll loop)"
    work = [s.name for s in found if s.name.split()[0] not in PLUMBING]
    return (work or [s.name for s in found] or ["?"])[0]


def check_key(command: str) -> str:
    """The identity of a check run: its check commands with arguments, no redirects."""
    return " && ".join(s.text for s in steps(command) if is_check(s))


def steps(command: str) -> list[Step]:
    found = (step(part.split()) for part in SEGMENT.split(command))
    return [s for s in found if s is not None]


def step(tokens: list[str]) -> Step | None:
    tokens = [t.strip("(){}") for t in tokens]
    tokens = [t for t in tokens if t]
    while tokens and (is_assignment(tokens[0]) or tokens[0] in WRAPPERS or tokens[0].isdigit()):
        tokens = tokens[1:]
    match tokens:
        case []:
            return None
        case [head, *_] if head in NOT_A_COMMAND:
            return None
        case ["nix", "develop", *rest] if {"-c", "--command"} & set(rest):
            flag = next(i for i, t in enumerate(rest) if t in {"-c", "--command"})
            return step(rest[flag + 1 :])
        case [head, *args]:
            head = Path(head).name or head
            words = [a for a in args if not a.startswith("-") and not REDIRECT.match(a)]
            words = [w for w in words[: SUBCOMMANDS.get(head, 0)] if "/" not in w or w.startswith(".#")]
            return Step(" ".join([head, *words]), " ".join([head, *without_redirects(args)]))


def is_assignment(token: str) -> bool:
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))


def without_redirects(args: list[str]) -> list[str]:
    kept: list[str] = []
    skip = False
    for arg in args:
        if skip:
            skip = False
        elif REDIRECT.match(arg):
            skip = re.sub(r"^\d+", "", arg) in {">", ">>", "<"}  # the target is the next token
        else:
            kept.append(arg)
    return kept


def is_check(s: Step) -> bool:
    return bool(FULL_CHECK.match(s.name) or STEP.match(s.name))


# --- Check waste -------------------------------------------------------------


@dataclass(frozen=True)
class Rerun:
    session: str
    agent: str
    command: str
    reason: str  # "no edit" or "doc-only edit"
    seconds: float


@dataclass(frozen=True)
class Chain:
    """A build or test step run in front of a full check that already runs it."""

    session: str
    agent: str
    step: str
    seconds: float


def check_waste(session: Session) -> tuple[list[Rerun], list[Chain]]:
    """Checks rerun with nothing changed, and steps run in front of a full check.

    An edit by any agent of the session counts as a change, so an orchestrator
    rerunning a check after its implementer edited is not flagged.
    """
    edits = sorted((c.start, is_doc_edit(c)) for a in session.agents for c in a.calls if is_edit(c))
    reruns: list[Rerun] = []
    chains: list[Chain] = []
    for agent in session.agents:
        last_run: dict[str, float] = {}
        earlier_steps: list[ToolCall] = []
        for call in (c for c in agent.calls if c.name == "Bash" and check_key(c.command)):
            key = check_key(call.command)
            if key in last_run:
                between = edits_between(edits, last_run[key], call.start)
                reason = "no edit" if not between else "doc-only edit" if all(between) else None
                if reason:
                    reruns.append(Rerun(session.id, agent.kind, key, reason, call.seconds or 0.0))
            last_run[key] = call.start
            found = [s for s in steps(call.command) if is_check(s)]
            full = [i for i, s in enumerate(found) if FULL_CHECK.match(s.name)]
            if not full:
                earlier_steps.append(call)
                continue
            chains += [Chain(session.id, agent.kind, s.text, 0.0) for s in found[: full[0]]]
            chains += [
                Chain(session.id, agent.kind, check_key(s.command), s.seconds or 0.0)
                for s in earlier_steps
                if not edits_between(edits, s.start, call.start)
            ]
            earlier_steps = []
    return reruns, chains


def edits_between(edits: list[tuple[float, bool]], start: float, end: float) -> list[bool]:
    return [doc for t, doc in edits if start < t < end]


def is_edit(call: ToolCall) -> bool:
    match call.name:
        case "Edit" | "Write" | "NotebookEdit" | "MultiEdit":
            return True
        case "Bash":
            return bool(CODE_CHANGING_BASH.search(call.command))
        case _:
            return False


def is_doc_edit(call: ToolCall) -> bool:
    path = str(call.input.get("file_path") or call.input.get("notebook_path") or "")
    return call.name != "Bash" and path.endswith(".md")


# --- Rendering ---------------------------------------------------------------


def render(window: Window, scope: str) -> str:
    sessions = window.sessions
    agents = [(s, a) for s in sessions for a in s.agents]
    calls = [(s, a, c) for s, a in agents for c in a.calls]
    sections = [
        f"# Session report ({scope})",
        summary(sessions),
        sessions_table(sessions),
        agent_types(agents),
        costliest_agents(agents),
        skills(agents),
        largest_results(calls),
        tool_times(calls),
        bash_commands(calls),
        checks_section(sessions),
        polling(calls),
        failures(calls),
    ]
    return "\n\n".join(sections) + "\n"


def summary(sessions: list[Session]) -> str:
    wall = sum(s.wall for s in sessions)
    wait = sum(s.human_wait for s in sessions)
    main = total(s.main.usage for s in sessions)
    subs = total(a.usage for s in sessions for a in s.subagents)
    calls = sum(len(a.responses) for s in sessions for a in s.agents)
    return "\n".join(
        [
            f"- Sessions: {len(sessions)}, agents: {sum(len(s.agents) for s in sessions)}, API calls: {calls}",
            f"- Wall clock: {hours(wall)} = work {hours(wall - wait)} + waiting on the person {hours(wait)}",
            f"- Tokens (in/cache read/cache write/out): main {tokens(main)}, subagents {tokens(subs)}",
        ]
    )


def sessions_table(sessions: list[Session]) -> str:
    ranked = sorted(sessions, key=lambda s: -sum(a.usage.context for a in s.agents))
    rows = [
        [
            s.id[:8],
            s.project,
            fmt_time(s.start),
            minutes(s.wall),
            minutes(s.human_wait),
            " ".join(f"/{c}" for c in dict.fromkeys(s.commands)) or "-",
            tokens(s.main.usage),
            kilo(s.main.peak_context),
            tokens(total(a.usage for a in s.subagents)),
            str(len(s.subagents)),
        ]
        for s in ranked[:12]
    ]
    header = ["session", "project", "start", "wall", "waiting", "commands", "main tokens", "main peak", "subagent tokens", "subagents"]
    return section("Sessions, costliest first", header, rows, len(ranked))


def agent_types(agents: list[tuple[Session, Agent]]) -> str:
    groups: dict[str, list[Agent]] = defaultdict(list)
    for _, agent in agents:
        groups[agent.kind].append(agent)
    ranked = sorted(groups.items(), key=lambda kv: -sum(a.usage.context for a in kv[1]))
    rows = [
        [kind, str(len(group)), str(sum(len(a.responses) for a in group)), tokens(total(a.usage for a in group)), kilo(max(a.peak_context for a in group))]
        for kind, group in ranked
    ]
    return section("Tokens by agent type", ["type", "agents", "API calls", "tokens", "peak context"], rows, len(rows))


def costliest_agents(agents: list[tuple[Session, Agent]]) -> str:
    subs = sorted(((s, a) for s, a in agents if a.kind != "main"), key=lambda sa: -sa[1].usage.context)
    rows = [
        [s.id[:8], a.kind, clip(a.description, 50), tokens(a.usage), kilo(a.peak_context), str(len(a.responses))]
        for s, a in subs[:TOP]
    ]
    return section("Costliest subagents", ["session", "type", "description", "tokens", "peak context", "API calls"], rows, len(subs))


def skills(agents: list[tuple[Session, Agent]]) -> str:
    groups: dict[str, list[Response]] = defaultdict(list)
    for _, agent in agents:
        for r in agent.responses:
            groups[r.skill or "(none)"].append(r)
    ranked = sorted(groups.items(), key=lambda kv: -sum(r.usage.context for r in kv[1]))
    rows = [[skill, str(len(rs)), tokens(total(r.usage for r in rs))] for skill, rs in ranked[:TOP]]
    return section("Tokens by skill (attributionSkill)", ["skill", "API calls", "tokens"], rows, len(ranked))


def largest_results(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    ranked = sorted(calls, key=lambda sac: -sac[2].result_chars)
    rows = [
        [kilo(c.result_chars), c.name, s.id[:8], a.kind, clip(what(c), 50)]
        for s, a, c in ranked[:TOP]
    ]
    images = [c for _, _, c in calls if c.images]
    table = section("Largest tool results (chars)", ["chars", "tool", "session", "agent", "what"], rows, len(ranked))
    return table + f"\n\nImages in tool results: {sum(c.images for c in images)} across {len(images)} calls."


def what(call: ToolCall) -> str:
    value = call.input.get("command") or call.input.get("file_path") or call.input.get("description") or call.input.get("pattern") or ""
    return " ".join(str(value).split())


def tool_times(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    groups: dict[tuple[str, str], list[float]] = defaultdict(list)
    for _, _, c in calls:
        if c.seconds is not None:
            groups[(c.name, c.mode)].append(c.seconds)
    ranked = sorted(groups.items(), key=lambda kv: -sum(kv[1]))
    rows = [
        [name, mode, str(len(ts)), minutes(sum(ts)), f"{statistics.median(ts):.0f}s", f"{max(ts):.0f}s"]
        for (name, mode), ts in ranked[:12]
    ]
    return section("Wall time per tool", ["tool", "mode", "calls", "total", "median", "max"], rows, len(ranked))


def bash_commands(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    groups: dict[str, list[ToolCall]] = defaultdict(list)
    for _, _, c in calls:
        if c.name == "Bash" and c.seconds is not None:
            groups[label(c.command)].append(c)
    ranked = sorted(groups.items(), key=lambda kv: -sum(c.seconds or 0 for c in kv[1]))
    rows = []
    for name, cs in ranked[:12]:
        fg = [c.seconds or 0 for c in cs if c.mode == "fg"]
        bg = [c.seconds or 0 for c in cs if c.mode == "bg"]
        failed = sum(1 for c in cs if isinstance(c.outcome, Failed))
        rows.append([clip(name, 60), str(len(fg)), minutes(sum(fg)), str(len(bg)), minutes(sum(bg)), f"{max(fg + bg):.0f}s", str(failed)])
    header = ["command", "fg calls", "fg time", "bg calls", "bg time", "max", "failed"]
    return section("Wall time per Bash command", header, rows, len(ranked))


def checks_section(sessions: list[Session]) -> str:
    reruns: list[Rerun] = []
    chains: list[Chain] = []
    for s in sessions:
        r, c = check_waste(s)
        reruns += r
        chains += c
    rerun_rows = [[x.session[:8], x.agent, clip(x.command, 60), x.reason, f"{x.seconds:.0f}s"] for x in sorted(reruns, key=lambda x: -x.seconds)[:8]]
    chain_rows = [[x.session[:8], x.agent, clip(x.step, 60), f"{x.seconds:.0f}s"] for x in sorted(chains, key=lambda x: -x.seconds)[:8]]
    return "\n\n".join(
        [
            f"## Redundant checks\n\nReruns with nothing changed since the same check: {len(reruns)}, {minutes(sum(x.seconds for x in reruns))}.",
            table(["session", "agent", "command", "since last run", "time"], rerun_rows),
            f"Build/test steps run before a full check with no edit between: {len(chains)}, {minutes(sum(x.seconds for x in chains))}.",
            table(["session", "agent", "step", "time"], chain_rows),
        ]
    )


def polling(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    bash = [(s, a, c) for s, a, c in calls if c.name == "Bash"]
    loops = [c for _, _, c in bash if SLEEP_LOOP.search(c.command)]
    fg_loops = [c for c in loops if c.mode == "fg"]
    timeouts = [c for c in fg_loops if isinstance(c.outcome, Failed) and "timed out" in c.outcome.signature.lower()]
    per_agent = Counter((s.id[:8], a.kind) for s, a, c in bash if PR_CHECKS.search(c.command) and "--watch" not in c.command)
    repeated = [f"{sid} {kind}: {n}" for (sid, kind), n in per_agent.most_common(5) if n > 2]
    return "\n".join(
        [
            "## Sleep and poll loops",
            "",
            f"- sleep/until/while loops: {len(loops)} calls, {len(fg_loops)} in the foreground taking {minutes(sum(c.seconds or 0 for c in fg_loops))}, {len(timeouts)} timed out",
            f"- `gh pr checks` without --watch: {sum(per_agent.values())} calls; agents polling it more than twice: {', '.join(repeated) or 'none'}",
        ]
    )


def failures(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    groups: dict[tuple[str, str, str], list[ToolCall]] = defaultdict(list)
    missing: Counter[str] = Counter()
    for _, _, c in calls:
        if isinstance(c.outcome, Failed):
            name = label(c.command) if c.name == "Bash" else ""
            groups[(c.name, name, c.outcome.signature)].append(c)
            missing.update(MISSING_TOOL.findall(c.outcome.signature))
    ranked = sorted(groups.items(), key=lambda kv: -len(kv[1]))
    rows = [
        [
            str(len(cs)),
            tool,
            clip(name, 40) or "-",
            ",".join(sorted({str(c.outcome.exit_code) for c in cs if isinstance(c.outcome, Failed) and c.outcome.exit_code is not None})) or "-",
            clip(sig, 80),
        ]
        for (tool, name, sig), cs in ranked[:12]
    ]
    total = sum(len(cs) for cs in groups.values())
    head = f"## Failing tool calls\n\n{total} failed calls in {len(groups)} groups. Missing tools: {', '.join(f'{t} ({n})' for t, n in missing.most_common(8)) or 'none'}."
    return head + "\n\n" + table(["count", "tool", "command", "exit", "error"], rows) + omitted(len(ranked), len(rows))


# --- Formatting --------------------------------------------------------------


def section(title: str, header: list[str], rows: list[list[str]], total: int) -> str:
    return f"## {title}\n\n" + table(header, rows) + omitted(total, len(rows))


def table(header: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "(none)"
    cell = lambda v: v.replace("|", "\\|")
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(lines + ["| " + " | ".join(cell(v) for v in row) + " |" for row in rows])


def omitted(total: int, shown: int) -> str:
    return f"\n\n{total - shown} more omitted." if total > shown else ""


def tokens(u: Usage) -> str:
    return "/".join(kilo(n) for n in (u.input, u.cache_read, u.cache_creation, u.output))


def kilo(n: int) -> str:
    return f"{n / 1e6:.1f}M" if n >= 1e6 else f"{n / 1e3:.0f}k" if n >= 1e3 else str(n)


def minutes(seconds: float) -> str:
    return f"{seconds / 60:.0f}m"


def hours(seconds: float) -> str:
    return f"{seconds / 3600:.1f}h"


def fmt_time(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M")


def clip(text: str, n: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


if __name__ == "__main__":
    main()
