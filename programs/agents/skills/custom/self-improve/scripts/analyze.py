#!/usr/bin/env python3
"""Measure where Claude Code sessions spend tokens and wall time, what the
quality loop bought for them, and how agents talk to each other.

Reads the transcripts under ~/.claude/projects and prints a compact markdown
report for an agent to read. Offline and read-only: it never calls `gh`.
Standard library only.

Usage: analyze.py [--since ISO] [--project SUBSTR] [--compare ISO] [--root DIR]

Without --since the window starts at the previous /self-improve invocation,
or covers everything when there is none. The latest invocation is the run
calling this script: its session is reported only up to that invocation.
--compare splits the window at a date and adds before and after medians.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass, field, fields
from datetime import UTC, datetime
from enum import Enum
from functools import cached_property
from itertools import pairwise
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar, NewType, assert_never, cast, override

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator

TOP = 8  # rows per table, which keeps the report near 15 KB
INPUT_WEIGHT = 1
CACHE_READ_WEIGHT = 0.1
CACHE_WRITE_WEIGHT = 1.25
OUTPUT_WEIGHT = 5
WEIGHTS = (
    f"input {INPUT_WEIGHT}, cache read {CACHE_READ_WEIGHT}, "
    f"cache write {CACHE_WRITE_WEIGHT}, output {OUTPUT_WEIGHT}"
)
# How long a prompt cache entry outlives its last use.
SUBAGENT_CACHE_LIFE = 5 * 60
MAIN_CACHE_LIFE = 60 * 60
REWRITE_SHARE = 0.5  # of a call's context written to cache, to count as a rewrite
TOP_REWRITERS = 5
# A watch-less `gh pr checks` above this many in one agent is reported.
ROUTINE_POLLS = 2
MIN_COMPARE_N = 5  # per side, below which a median is noise

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

SessionId = NewType("SessionId", str)
AgentId = NewType("AgentId", str)  # the transcript's name, unique within a session
ToolUseId = NewType("ToolUseId", str)
ResponseKey = NewType("ResponseKey", str)  # the message id, else the request id

type ReadBound = int | str | None  # a Read's offset or limit, a string as sent


def main() -> None:
    args = parse_args()
    sessions = load_sessions(args.root)
    window = select_window(sessions, args.since, args.project)
    print(render(window, describe_window(window.since, args.project), args.compare))


class Args(argparse.Namespace):
    since: datetime | None = None
    project: str | None = None
    compare: datetime | None = None
    root: Path = Path.home() / ".claude" / "projects"


def parse_args() -> Args:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    _ = parser.add_argument(
        "--since",
        type=utc_time,
        help="ISO date or time; default: the previous /self-improve run",
    )
    _ = parser.add_argument(
        "--project", help="only sessions whose working directory contains this"
    )
    _ = parser.add_argument(
        "--compare", type=utc_time, help="ISO date or time to split the window at"
    )
    _ = parser.add_argument(
        "--root",
        type=Path,
        help=argparse.SUPPRESS,
    )
    return parser.parse_args(namespace=Args())


def utc_time(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(UTC)


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

    @property
    def effective(self) -> float:
        """What the call costs in input tokens: reads are cheap, writes and output are not."""
        return (
            self.input * INPUT_WEIGHT
            + self.cache_read * CACHE_READ_WEIGHT
            + self.cache_creation * CACHE_WRITE_WEIGHT
            + self.output * OUTPUT_WEIGHT
        )

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
    at: float  # its first line
    calls: list[ToolCall]


@dataclass(frozen=True)
class Foreground:
    end: float


@dataclass(frozen=True)
class Background:
    end: float | None  # None: still running when the transcript ends


@dataclass(frozen=True)
class Unanswered:
    """A tool call whose result never reached the transcript."""


type Timing = Foreground | Background | Unanswered
Interval = tuple[float, float]
StreamPoint = tuple[
    float, int
]  # a call's start, then its position among calls sharing that start
ASK = "AskUserQuestion"


@dataclass(frozen=True)
class Ok:
    pass


@dataclass(frozen=True)
class Failed:
    exit_code: int | None
    signature: str


type Outcome = Ok | Failed


@dataclass(frozen=True, slots=True)
class BashTool:
    name: ClassVar[str] = "Bash"
    command: str


@dataclass(frozen=True, slots=True)
class ReadTool:
    name: ClassVar[str] = "Read"
    path: str
    offset: ReadBound
    limit: ReadBound


@dataclass(frozen=True, slots=True)
class EditTool:
    name: ClassVar[str] = "Edit"
    path: str


@dataclass(frozen=True, slots=True)
class WriteTool:
    name: ClassVar[str] = "Write"
    path: str


@dataclass(frozen=True, slots=True)
class MultiEditTool:
    name: ClassVar[str] = "MultiEdit"
    path: str


@dataclass(frozen=True, slots=True)
class NotebookEditTool:
    name: ClassVar[str] = "NotebookEdit"
    path: str


@dataclass(frozen=True, slots=True)
class HandbackTool:
    name: ClassVar[str] = "SubagentHandback"
    message: str


@dataclass(frozen=True, slots=True)
class OtherTool:
    """Any other tool, or one of the above whose input lacks its required field."""

    name: str
    label: str | None  # what a report names the call by


type Tool = (
    BashTool
    | ReadTool
    | EditTool
    | WriteTool
    | MultiEditTool
    | NotebookEditTool
    | HandbackTool
    | OtherTool
)


@dataclass
class ToolCall:
    id: ToolUseId
    tool: Tool
    start: float
    position: int  # in its transcript's stream; siblings can share a start
    timing: Timing = Unanswered()
    outcome: Outcome = Ok()
    result_chars: int = 0
    images: int = 0

    @property
    def name(self) -> str:
        return self.tool.name

    @property
    def command(self) -> str | None:
        match self.tool:
            case BashTool(command=command):
                return command
            case (
                ReadTool()
                | EditTool()
                | WriteTool()
                | MultiEditTool()
                | NotebookEditTool()
                | HandbackTool()
                | OtherTool()
            ):
                return None
            case _:
                assert_never(self.tool)

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
    id: AgentId
    kind: str  # "main" or the subagent's agentType
    description: str
    responses: list[Response]
    calls: list[ToolCall]
    parent: AgentId | None = None  # None when the main agent spawned it
    brief: str = ""  # the first user text: a subagent's prompt
    instruction_chars: int = 0  # the instructions files sent before its first call
    listing_chars: int = 0  # the skill listing sent before its first call
    texts: list[str] = field(default_factory=list)  # assistant text blocks, in order
    start: float = 0.0
    end: float = 0.0

    @property
    def usage(self) -> Usage:
        return total(r.usage for r in self.responses)

    @property
    def report(self) -> str:
        """What the agent handed back: its last hand-back, else its last text."""
        handbacks = [
            m for c in self.calls if (m := handback_message(c.tool)) is not None
        ]
        return (handbacks or self.texts or [""])[-1]

    @property
    def wall(self) -> float:
        return self.end - self.start

    @property
    def peak_context(self) -> int:
        return max((r.usage.context for r in self.responses), default=0)

    @property
    def first_context(self) -> int:
        """Its start-up size: the context of its first real call, 0 with none. An API error is a line with no usage."""
        return next((r.usage.context for r in self.responses if r.usage.context), 0)


def handback_message(tool: Tool) -> str | None:
    match tool:
        case HandbackTool(message=message):
            return message
        case (
            BashTool()
            | ReadTool()
            | EditTool()
            | WriteTool()
            | MultiEditTool()
            | NotebookEditTool()
            | OtherTool()
        ):
            return None
        case _:
            assert_never(tool)


def effective(agents: Iterable[Agent]) -> float:
    return total(a.usage for a in agents).effective


@dataclass(frozen=True)
class Prompt:
    """One thing the person typed: a slash command, or free text with no commands."""

    at: float
    commands: list[str]


@dataclass
class Session:
    id: SessionId
    path: Path
    project: str
    cwd: str
    start: float
    end: float
    commands: list[str]
    invocations: list[float]  # when the main agent was handed /self-improve
    prompts: list[Prompt]
    human_wait: float  # seconds the session sat waiting on the person
    main: Agent
    subagents: list[Agent]

    @property
    def agents(self) -> list[Agent]:
        return [self.main, *self.subagents]

    @cached_property
    def by_id(self) -> dict[AgentId, Agent]:
        return {a.id: a for a in self.subagents}

    @property
    def wall(self) -> float:
        return self.end - self.start


class LoopStep(Enum):
    ORCHESTRATOR = "orchestrator"
    RESEARCH = "research"
    IMPLEMENT = "implement"
    REFACTOR = "refactor"
    REVIEW_1 = "review 1"
    REVIEW_2 = "review 2"
    FINAL_REVIEW = "final review"
    FIX = "fix"
    PR_DESCRIPTION = "pr description"
    OTHER = "other"


REVIEW_PASSES = (LoopStep.REVIEW_1, LoopStep.REVIEW_2, LoopStep.FINAL_REVIEW)


@dataclass(frozen=True)
class ParsedReview:
    """The counts of one pragmatic-review report."""

    raised: int
    survived: int
    major: int
    minor: int
    nit: int
    met: int
    not_met: int
    unverified: int
    do_not_merge: int


@dataclass(frozen=True)
class Unparsed:
    """A review report without the `N raised, M survived` verdict: its format
    drifted. Its table rows still count."""

    major: int
    minor: int
    nit: int


type Review = ParsedReview | Unparsed


@dataclass(frozen=True)
class ByAgent:
    step: LoopStep
    usage: Usage  # the review agent and its children


@dataclass(frozen=True)
class ByMain:
    """Written by the main agent, whose tokens cannot be attributed to the review."""


type ReviewSource = ByAgent | ByMain


@dataclass(frozen=True)
class ReviewRun:
    source: ReviewSource
    review: Review


@dataclass(frozen=True)
class FollowUp:
    """What a parent's calls did with one child's hand-back."""

    step: LoopStep
    rereads: list[ToolCall]
    reverifies: list[ToolCall]


@dataclass(frozen=True)
class RepeatedRead:
    """A read or read-only command two or more agents of a session ran."""

    what: str
    agents: int
    runs: int
    repeated_chars: int  # every run but the largest


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
    invocations: list[float] = field(default_factory=list)
    prompts: list[Prompt] = field(default_factory=list)
    human_gaps: list[Interval] = field(default_factory=list)  # before each human prompt
    cwd: str = ""


@dataclass(frozen=True, slots=True)
class ToolUse:
    id: ToolUseId
    tool: Tool


@dataclass(frozen=True, slots=True)
class Text:
    text: str


type AssistantBlock = ToolUse | Text


@dataclass(frozen=True, slots=True)
class AssistantLine:
    """One content block of a model call, which can span several lines."""

    key: ResponseKey | None
    usage: Usage
    skill: str | None
    blocks: list[AssistantBlock]


@dataclass(frozen=True, slots=True)
class ToolResult:
    tool_use_id: ToolUseId
    text: str
    images: int
    is_error: bool


@dataclass(frozen=True, slots=True)
class ToolResultsLine:
    results: list[ToolResult]
    started_background: bool


@dataclass(frozen=True, slots=True)
class UserLine:
    text: str
    human: bool


@dataclass(frozen=True, slots=True)
class NotificationLine:
    """A line that carries no message, only task notifications."""

    text: str


@dataclass(frozen=True, slots=True)
class InstructionFiles:
    chars: int


@dataclass(frozen=True, slots=True)
class SkillListing:
    chars: int


type StartupPart = InstructionFiles | SkillListing


@dataclass(frozen=True, slots=True)
class AttachmentLine:
    """Text the harness attached: task notifications, or a part of the start-up."""

    prompt: str
    startup: StartupPart | None


@dataclass(frozen=True, slots=True)
class OtherLine:
    """A line of a type nothing reads: it only moves the clock."""


type LineBody = (
    AssistantLine
    | ToolResultsLine
    | UserLine
    | NotificationLine
    | AttachmentLine
    | OtherLine
)


@dataclass(frozen=True, slots=True)
class Line:
    at: float
    cwd: str
    body: LineBody


@dataclass(frozen=True, slots=True)
class SubagentMeta:
    kind: str
    description: str
    parent: AgentId | None  # the spawning subagent's id


SELF = "self-improve"
COMMAND_NAME = re.compile(r"<command-name>/?([\w:-]+)</command-name>")
NOTIFICATION = re.compile(
    r"<task-notification>(.*?)(?:</task-notification>|$)", re.DOTALL
)
EXIT_CODE = re.compile(r"exit code (\d+)", re.IGNORECASE)
# A subagent's transcript has no `toolUseResult`: only the result text tells.
BACKGROUND_START = re.compile(
    "|".join(
        (
            r"Command running in background with ID",
            r"Command did not complete within its \S+ timeout and was moved to the background",
            r"Async agent launched",
        )
    )
)


def load_sessions(root: Path) -> list[Session]:
    sessions = [load_session(path) for path in sorted(root.glob("*/*.jsonl"))]
    return [s for s in sessions if s is not None]


def load_session(path: Path, until: float | None = None) -> Session | None:
    """The session at `path`, keeping only events before `until` when given."""
    main = parse_transcript(path, "main", "", until)
    subs = [
        parse_subagent(p, until)
        for p in sorted(path.with_suffix("").glob("subagents/agent-*.jsonl"))
    ]
    times = main.times + [t for s in subs for t in s.times]
    if not times:
        return None
    return Session(
        id=SessionId(path.stem),
        path=path,
        project=project_name(main.cwd),
        cwd=main.cwd,
        start=min(times),
        end=max(times),
        commands=main.commands,
        invocations=main.invocations,
        prompts=main.prompts,
        human_wait=waiting_seconds(
            main.human_gaps, main.agent, [main.agent, *(s.agent for s in subs)]
        ),
        main=main.agent,
        subagents=[s.agent for s in subs],
    )


def parse_subagent(path: Path, until: float | None) -> Transcript:
    meta = parse_meta(path.with_name(path.stem + ".meta.json"))
    transcript = parse_transcript(path, meta.kind, meta.description, until)
    transcript.agent.parent = meta.parent
    return transcript


def parse_meta(path: Path) -> SubagentMeta:
    raw = as_object(parse_json(path.read_text())) if path.exists() else {}
    parent = optional_text(raw.get("parentAgentId"))
    return SubagentMeta(
        text_of(raw.get("agentType"), "unknown"),
        text_of(raw.get("description")),
        None if parent is None else AgentId(parent),
    )


def question_intervals(agent: Agent) -> list[Interval]:
    return [
        (c.start, c.start + c.seconds)
        for c in agent.calls
        if c.name == ASK and c.seconds is not None
    ]


def project_name(cwd: str) -> str:
    """The repository or directory a session ran in, without its worktree suffix."""
    return Path(cwd.split("/.claude/worktrees/", maxsplit=1)[0]).name or "?"


def waiting_seconds(
    human_gaps: list[Interval], main: Agent, agents: list[Agent]
) -> float:
    """Time spent waiting on the person: every question the main agent left open
    (a subagent cannot ask), plus each gap before a human prompt in which no
    tool call of any agent was running."""
    asks = question_intervals(main)
    busy = [
        (c.start, c.start + c.seconds)
        for a in agents
        for c in a.calls
        if c.name != ASK and c.seconds is not None
    ]
    idle = [part for gap in human_gaps for part in subtract(gap, merge(busy))]
    return sum(end - start for start, end in merge(asks + idle))


def merge(intervals: list[Interval]) -> list[Interval]:
    """Sorted, non-overlapping intervals covering the same time."""
    out: list[Interval] = []
    for start, end in sorted(intervals):
        if out and start <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], end))
        else:
            out.append((start, end))
    return out


def subtract(interval: Interval, merged: list[Interval]) -> Iterator[Interval]:
    """The parts of `interval` outside the sorted, non-overlapping `merged`."""
    start, end = interval
    for cut_start, cut_end in merged:
        if cut_start >= end:
            break
        if cut_end > start:
            if cut_start > start:
                yield start, cut_start
            start = max(start, cut_end)
    if start < end:
        yield start, end


def parse_transcript(
    path: Path, kind: str, description: str, until: float | None
) -> Transcript:
    agent_id = AgentId(path.stem.removeprefix("agent-"))
    out = Transcript(Agent(agent_id, kind, description, [], []))
    responses: dict[ResponseKey, Response] = {}
    calls: dict[ToolUseId, ToolCall] = {}
    previous: float | None = None
    for line in map(parse_line, read_jsonl(path)):
        if line is None or (until is not None and line.at >= until):
            continue
        out.cwd = out.cwd or line.cwd
        match line.body:
            case AssistantLine() as body:
                record_assistant(responses, calls, body, line.at, out.agent.texts)
            case ToolResultsLine() as body:
                record_results(calls, body, line.at)
            case UserLine() as body:
                record_user(out, calls, body, line.at, previous)
            case NotificationLine(text):
                record_notifications(calls, text, line.at)
            case AttachmentLine(prompt, startup):
                record_notifications(calls, prompt, line.at)
                if not responses:
                    record_startup(out.agent, startup)
            case OtherLine():
                pass
            case _:
                assert_never(line.body)
        out.times.append(line.at)
        previous = line.at
    out.agent.responses = list(responses.values())
    out.agent.calls = sorted(calls.values(), key=lambda c: c.start)
    out.agent.start, out.agent.end = (
        (min(out.times), max(out.times)) if out.times else (0.0, 0.0)
    )
    return out


def record_assistant(
    responses: dict[ResponseKey, Response],
    calls: dict[ToolUseId, ToolCall],
    line: AssistantLine,
    ts: float,
    texts: list[str],
) -> None:
    key = line.key or ResponseKey(f"line-{len(responses)}")
    match responses.get(key):
        case Response(at=start, calls=response_calls):
            pass
        case None:
            start, response_calls = ts, []
    responses[key] = Response(line.usage, line.skill, start, response_calls)
    for block in line.blocks:
        match block:
            case ToolUse(call_id, tool):
                call = ToolCall(call_id, tool, ts, len(calls))
                calls[call.id] = call
                response_calls.append(call)
            case Text(text):
                texts.append(text)
            case _:
                assert_never(block)
    # A line is stamped when its block finished streaming and most tools start once the
    # response has ended, but a tool can answer mid-stream, and then this line is past its end.
    for call in response_calls:
        if isinstance(call.timing, Unanswered):
            call.start = ts


def record_results(
    calls: dict[ToolUseId, ToolCall], line: ToolResultsLine, ts: float
) -> None:
    for result in line.results:
        call = calls.get(result.tool_use_id)
        if call is not None:
            record_result(call, result, ts, started=line.started_background)


def record_user(
    out: Transcript,
    calls: dict[ToolUseId, ToolCall],
    line: UserLine,
    ts: float,
    previous: float | None,
) -> None:
    names = captures(COMMAND_NAME, line.text)
    out.commands += names
    out.invocations += [ts] if SELF in names else []
    out.agent.brief = out.agent.brief or line.text
    if line.human:
        out.prompts.append(Prompt(ts, names))
        out.human_gaps += [(previous, ts)] if previous is not None else []
    record_notifications(calls, line.text, ts)


def read_jsonl(path: Path) -> Iterator[dict[str, Json]]:
    with path.open(errors="replace") as lines:
        for line in lines:
            try:
                event = parse_json(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                yield event


def parse_json(text: str) -> Json:
    return cast("Json", json.loads(text))


def parse_line(event: dict[str, Json]) -> Line | None:
    """The transcript line `event`, None when it has no timestamp."""
    ts = parse_time(event.get("timestamp"))
    if ts is None:
        return None
    return Line(ts, text_of(event.get("cwd")), parse_body(event))


def parse_body(event: dict[str, Json]) -> LineBody:
    message = as_object(event.get("message"))
    content = message.get("content")
    match event.get("type"):
        case "assistant":
            return AssistantLine(
                response_key(message.get("id"), event.get("requestId")),
                to_usage(as_object(message.get("usage"))),
                optional_text(event.get("attributionSkill")),
                parse_assistant_blocks(content),
            )
        case "user" if is_tool_results(content):
            return ToolResultsLine(
                parse_tool_results(content),
                started_background(event.get("toolUseResult")),
            )
        case "user":
            origin = as_object(event.get("origin"))
            return UserLine(plain_text(content), origin.get("kind") == "human")
        case "queue-operation":
            return NotificationLine(str(event.get("content") or ""))
        case "attachment":
            attachment = as_object(event.get("attachment"))
            return AttachmentLine(
                str(attachment.get("prompt") or ""), parse_startup_part(attachment)
            )
        case _:
            return OtherLine()


def parse_startup_part(attachment: dict[str, Json]) -> StartupPart | None:
    match attachment.get("type"):
        case "instructions":
            files = blocks(attachment.get("files"))
            return InstructionFiles(
                sum(len(str(f.get("content") or "")) for f in files)
            )
        case "skill_listing":
            return SkillListing(len(str(attachment.get("content") or "")))
        case _:
            return None


def response_key(message_id: Json, request_id: Json) -> ResponseKey | None:
    match text_of(message_id) or text_of(request_id):
        case "":
            return None
        case key:
            return ResponseKey(key)


def parse_assistant_blocks(content: Json) -> list[AssistantBlock]:
    parsed = map(parse_assistant_block, blocks(content))
    return [block for block in parsed if block is not None]


def parse_assistant_block(block: dict[str, Json]) -> AssistantBlock | None:
    match block:
        case {"type": "tool_use", "id": str(call_id)}:
            return ToolUse(
                ToolUseId(call_id),
                parse_tool(
                    text_of(block.get("name"), "?"), as_object(block.get("input"))
                ),
            )
        case {"type": "text"}:
            return Text(str(block.get("text", "")))
        case _:
            return None


def parse_tool(name: str, raw: dict[str, Json]) -> Tool:  # noqa: PLR0911 - one return per tool
    match (name, raw):
        case (BashTool.name, {"command": str(command)}):
            return BashTool(command)
        case (ReadTool.name, {"file_path": str(path)}):
            offset, limit = read_bound(raw.get("offset")), read_bound(raw.get("limit"))
            return ReadTool(path, offset, limit)
        case (EditTool.name, {"file_path": str(path)}):
            return EditTool(path)
        case (WriteTool.name, {"file_path": str(path)}):
            return WriteTool(path)
        case (MultiEditTool.name, {"file_path": str(path)}):
            return MultiEditTool(path)
        case (NotebookEditTool.name, {"notebook_path": str(path)}):
            return NotebookEditTool(path)
        case (HandbackTool.name, {"message": str(message)}):
            return HandbackTool(message)
        case _:
            return OtherTool(name, tool_label(raw))


def tool_label(raw: dict[str, Json]) -> str | None:
    values = (
        raw.get(key) for key in ("command", "file_path", "description", "pattern")
    )
    return next((str(value) for value in values if value), None)


def read_bound(value: Json) -> ReadBound:
    match value:
        case int() | str():
            return value
        case _:
            return None


def parse_tool_results(content: Json) -> list[ToolResult]:
    parsed = map(parse_tool_result, blocks(content))
    return [result for result in parsed if result is not None]


def parse_tool_result(block: dict[str, Json]) -> ToolResult | None:
    match block:
        case {"type": "tool_result", "tool_use_id": str(tool_use_id)}:
            text, images = result_text(block.get("content"))
            return ToolResult(
                ToolUseId(tool_use_id), text, images, bool(block.get("is_error"))
            )
        case _:
            return None


def started_background(extra: Json) -> bool:
    return isinstance(extra, dict) and bool(
        extra.get("backgroundTaskId") or extra.get("isAsync")
    )


def as_object(value: Json) -> dict[str, Json]:
    return value if isinstance(value, dict) else {}


def text_of(value: Json, default: str = "") -> str:
    return value if isinstance(value, str) else default


def optional_text(value: Json) -> str | None:
    return value if isinstance(value, str) else None


def token_count(value: Json) -> int:
    return value if isinstance(value, int) else 0


def parse_time(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    return datetime.fromisoformat(value).timestamp()


def to_usage(raw: dict[str, Json]) -> Usage:
    return Usage(
        token_count(raw.get("input_tokens")),
        token_count(raw.get("cache_read_input_tokens")),
        token_count(raw.get("cache_creation_input_tokens")),
        token_count(raw.get("output_tokens")),
    )


def blocks(content: Json) -> list[dict[str, Json]]:
    return (
        [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
    )


def is_tool_results(content: Json) -> bool:
    return any(b.get("type") == "tool_result" for b in blocks(content))


def plain_text(content: Json) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(str(b.get("text", "")) for b in blocks(content))


def record_result(
    call: ToolCall, result: ToolResult, ts: float, *, started: bool
) -> None:
    text = result.text
    call.result_chars, call.images = len(text), result.images
    call.timing = (
        Background(None) if started or BACKGROUND_START.match(text) else Foreground(ts)
    )
    if result.is_error:
        call.outcome = Failed(exit_code(text), signature(text))
    elif "command not found" in text:
        call.outcome = Failed(None, signature(text))


def result_text(content: Json) -> tuple[str, int]:
    if isinstance(content, str):
        return content, 0
    items = blocks(content)
    text = "\n".join(str(b.get("text", "")) for b in items if b.get("type") == "text")
    return text, sum(1 for b in items if b.get("type") == "image")


def record_notifications(
    calls: dict[ToolUseId, ToolCall], text: str, ts: float
) -> None:
    """A background call ends at its first task notification."""
    for body in captures(NOTIFICATION, text):
        call = calls.get(ToolUseId(tag(body, "tool-use-id")))
        if call is None or call.timing != Background(None):
            continue
        call.timing = Background(ts)
        if tag(body, "status") == "failed":
            summary = tag(body, "summary")
            call.outcome = Failed(exit_code(summary), clip(summary, 100))


def captures(pattern: re.Pattern[str], text: str) -> list[str]:
    """Each match's first group: `findall`, which typeshed types as Any."""
    return [found.group(1) for found in pattern.finditer(text)]


def record_startup(agent: Agent, startup: StartupPart | None) -> None:
    match startup:
        case InstructionFiles(chars):
            agent.instruction_chars += chars
        case SkillListing(chars):
            agent.listing_chars += chars
        case None:
            pass
        case _:
            assert_never(startup)


def tag(body: str, name: str) -> str:
    found = re.search(rf"<{name}>(.*?)</{name}>", body, re.DOTALL)
    return found.group(1) if found else ""


def exit_code(text: str) -> int | None:
    found = EXIT_CODE.search(text)
    return int(found.group(1)) if found else None


ERROR_LINE = re.compile(
    r"error|not found|no such file|fatal|denied|failed|traceback|timed out|blocked|refused",
    re.IGNORECASE,
)


def signature(text: str) -> str:
    """The error line that identifies a failure, with volatile parts masked."""
    lines = [
        raw.strip()
        for raw in text.splitlines()
        if raw.strip() and not raw.lower().startswith("exit code")
    ]
    line = next(filter(ERROR_LINE.search, lines), lines[0] if lines else "")
    line = re.sub(r"/nix/store/[a-z0-9]{32}-", "/nix/store/…-", line)
    line = re.sub(r"\b[0-9a-f]{7,}\b", "…", line)
    return clip(re.sub(r"(?<![A-Za-z])\d+", "N", line), 100)


# --- Window ------------------------------------------------------------------


def select_window(
    sessions: list[Session], since: datetime | None, project: str | None
) -> Window:
    """Sessions starting at or after the window start, the current run cut off at its invocation."""
    runs = sorted(
        ((ts, s) for s in sessions for ts in s.invocations), key=lambda run: run[0]
    )
    start = since.timestamp() if since else (runs[-2][0] if len(runs) > 1 else None)
    chosen = [
        s
        for s in without_current_run(sessions, runs[-1] if runs else None)
        if (start is None or s.start >= start) and (project is None or project in s.cwd)
    ]
    return Window(start, sorted(chosen, key=lambda s: s.start))


def without_current_run(
    sessions: list[Session], current: tuple[float, Session] | None
) -> list[Session]:
    """Every session, the one running this script reloaded without its events from the invocation on."""
    match current:
        case None:
            return sessions
        case (invoked, run):
            others = [s for s in sessions if s.id != run.id]
            truncated = load_session(run.path, until=invoked)
            return others if truncated is None else [*others, truncated]


def describe_window(since: float | None, project: str | None) -> str:
    scope = f"since {fmt_time(since)}" if since is not None else "all transcripts"
    return scope + (f", project matching `{project}`" if project else "")


# --- Bash commands -----------------------------------------------------------


@dataclass(frozen=True)
class Step:
    """One simple command inside a Bash call."""

    name: str  # the tool and its subcommand, e.g. "nix run .#test"
    text: str  # the full command without wrappers and redirects


SUBCOMMANDS = {
    "just": 1,
    "nix": 2,
    "git": 1,
    "gh": 2,
    "cabal": 1,
    "npm": 2,
    "pnpm": 2,
    "cargo": 1,
    "systemctl": 1,
}
WRAPPERS = {"env", "time", "nice", "timeout", "sudo", "exec", "command"}
# Reserved words a command can follow in its own segment, as in `if just check`.
BEFORE_A_COMMAND = {"if", "elif", "then", "else", "while", "until", "do", "!"}
NOT_A_COMMAND = {"cd", "export", "set", "source", "."}
PLUMBING = {
    "echo",
    "printf",
    "tail",
    "head",
    "grep",
    "rg",
    "sort",
    "uniq",
    "wc",
    "cut",
    "tr",
    "jq",
    "awk",
    "sed",
    "tee",
    "xargs",
    "true",
    "false",
    "sleep",
    "for",
    "done",
    "fi",
}
# `&` only as an operator: not in `2>&1`, `&>` or a word such as a URL's query.
SEGMENT = re.compile(r"&&|\|\||\|&|;|\||\n|(?<=\s)&(?=\s|$)")
QUOTED = re.compile(r"""'[^']*'|"(?:[^"\\]|\\.)*\"""", re.DOTALL)
HEREDOC = re.compile(r"""(?<!<)<<(?!<)-?\s*['"\\]?([\w.-]+)""")
REDIRECT = re.compile(r"^(\d*|&)(>>?|<)&?\S*$")
FULL_CHECK = re.compile(r"^(just check|nix flake check)$")
STEP = re.compile(
    r"^(just (build|test|lint|fmt|typecheck)|nix build|nix build \.#\S+|nix run \.#(build|test|lint|check)|cabal (build|test)|npm (test|run)|pnpm (test|run)|cargo (build|test|clippy))$"
)
SHELL_EDIT = r"sed -i|\btee\b|\bcat\s*>|git (pull|merge|rebase|reset|checkout|switch|cherry-pick|am|apply|stash)\b"
PYTHON_WRITE = r"python[\d.]*\b[^\n]*<<.*?(?:\.write_(?:text|bytes)\(|open\([^)\n]*,\s*(?:mode\s*=\s*)?['\"][rbt]*[wax+]|\.open\(\s*(?:mode\s*=\s*)?['\"][rbt]*[wax+][rbt+]*['\"])"
CODE_CHANGING_BASH = re.compile(f"{SHELL_EDIT}|{PYTHON_WRITE}", re.DOTALL)
SLEEP_LOOP = re.compile(r"\bsleep\s+\d|\buntil\b|\bwhile\b.*\bsleep\b", re.DOTALL)
PR_CHECKS = re.compile(r"\bgh pr checks\b")
PR_READY = re.compile(r"\bgh pr ready\b")
PR_CREATE = re.compile(r"\bgh pr create\b")
MISSING_TOOL = re.compile(r"([\w.+-]+): (?:command )?not found\b")


def label(command: str) -> str:
    """What a Bash call is, for grouping: its checks, else its main command."""
    return label_of(command, steps(command))


def label_of(command: str, found: list[Step]) -> str:
    """`label`, with the steps read from `command` by the caller."""
    checks = [s.name for s in found if is_check(s)]
    if checks:
        return " && ".join(dict.fromkeys(checks))
    if SLEEP_LOOP.search(command):
        return "(sleep/poll loop)"
    work = [s.name for s in found if s.name.split()[0] not in PLUMBING]
    return (work or [s.name for s in found] or ["?"])[0]


def check_key(command: str) -> str:
    """The identity of a check run: its check commands with arguments, no redirects."""
    return key_of(steps(command))


def key_of(found: list[Step]) -> str:
    """`check_key`, with the steps read by the caller."""
    return " && ".join(s.text for s in found if is_check(s))


def steps(command: str) -> list[Step]:
    text = QUOTED.sub(lambda q: SEGMENT.sub(" ", q[0]), executed_lines(command))
    found = (step(part.split()) for part in SEGMENT.split(text))
    return [s for s in found if s is not None]


def executed_lines(command: str) -> str:
    """`command` with line continuations joined, heredoc bodies and comment lines gone."""
    kept: list[str] = []
    closing: list[str] = []  # the delimiters of the heredocs still open, in order
    for line in command.replace("\\\n", " ").split("\n"):
        match closing:
            case [delimiter, *rest]:
                if line.lstrip("\t") == delimiter:
                    closing = rest
            case _ if line.lstrip().startswith("#"):
                pass
            case _:
                kept.append(line)
                closing = HEREDOC.findall(line)
    return "\n".join(kept)


def step(tokens: list[str]) -> Step | None:
    tokens = [t.strip("(){}") for t in tokens]
    tokens = [t for t in tokens if t]
    while tokens and (
        is_assignment(tokens[0])
        or tokens[0] in WRAPPERS
        or tokens[0] in BEFORE_A_COMMAND
        or tokens[0].isdigit()
    ):
        tokens = tokens[1:]
    match tokens:
        case [head, *_] if head in NOT_A_COMMAND:
            return None
        case ["git", "-C", _, *rest]:
            return step(["git", *rest])
        case ["nix", "develop", *rest] if {"-c", "--command"} & set(rest):
            flag = next(i for i, t in enumerate(rest) if t in {"-c", "--command"})
            return step(rest[flag + 1 :])
        case [head, *args]:
            head = Path(head).name or head
            words = [a for a in args if not a.startswith("-") and not REDIRECT.match(a)]
            words = [
                w
                for w in words[: SUBCOMMANDS.get(head, 0)]
                if "/" not in w or w.startswith(".#")
            ]
            return Step(
                " ".join([head, *words]), " ".join([head, *without_redirects(args)])
            )
        case _:
            return None


def is_assignment(token: str) -> bool:
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))


def without_redirects(args: list[str]) -> list[str]:
    kept: list[str] = []
    skip = False
    for arg in args:
        if skip:
            skip = False
        elif REDIRECT.match(arg):
            skip = re.sub(r"^(\d+|&)", "", arg) in {
                ">",
                ">>",
                "<",
            }  # the target is the next token
        else:
            kept.append(arg)
    return kept


def is_check(s: Step) -> bool:
    return bool(FULL_CHECK.match(s.name) or STEP.match(s.name))


# --- Check waste -------------------------------------------------------------


@dataclass(frozen=True)
class Rerun:
    session: SessionId
    agent: str
    command: str
    reason: str  # "no edit" or "doc-only edit"
    seconds: float


@dataclass(frozen=True)
class Chain:
    """A build or test step run in front of a full check that already runs it."""

    session: SessionId
    agent: str
    step: str
    seconds: float


def check_waste(session: Session) -> tuple[list[Rerun], list[Chain]]:
    """Checks rerun with nothing changed, and steps run in front of a full check.

    An edit by any agent of the session counts as a change, so an orchestrator
    rerunning a check after its implementer edited is not flagged.
    """
    edits = sorted(
        (stream_point(c), is_doc_edit(c))
        for a in session.agents
        for c in a.calls
        if is_edit(c)
    )
    reruns: list[Rerun] = []
    chains: list[Chain] = []
    for agent in session.agents:
        last_run: dict[str, StreamPoint] = {}
        earlier_steps: list[tuple[ToolCall, str]] = []
        for call, command in bash_runs(agent.calls):
            key = check_key(command)
            if not key:
                continue
            if key in last_run:
                between = edits_between(edits, last_run[key], stream_point(call))
                reason = (
                    "no edit"
                    if not between
                    else "doc-only edit"
                    if all(between)
                    else None
                )
                if reason:
                    reruns.append(
                        Rerun(session.id, agent.kind, key, reason, call.seconds or 0.0)
                    )
            last_run[key] = stream_point(call)
            found = [s for s in steps(command) if is_check(s)]
            full = [i for i, s in enumerate(found) if FULL_CHECK.match(s.name)]
            if not full:
                earlier_steps.append((call, key))
                continue
            chains += [
                Chain(session.id, agent.kind, s.text, 0.0) for s in found[: full[0]]
            ]
            chains += [
                Chain(session.id, agent.kind, step_key, step.seconds or 0.0)
                for step, step_key in earlier_steps
                if not edits_between(edits, stream_point(step), stream_point(call))
            ]
            earlier_steps = []
    return reruns, chains


def bash_runs(calls: Iterable[ToolCall]) -> Iterator[tuple[ToolCall, str]]:
    return ((c, command) for c in calls if (command := c.command) is not None)


def stream_point(call: ToolCall) -> StreamPoint:
    return call.start, call.position


def edits_between(
    edits: list[tuple[StreamPoint, bool]], start: StreamPoint, end: StreamPoint
) -> list[bool]:
    return [doc for point, doc in edits if start < point < end]


def is_edit(call: ToolCall) -> bool:
    match call.tool:
        case EditTool() | WriteTool() | NotebookEditTool() | MultiEditTool():
            return True
        case BashTool(command=command):
            return bool(CODE_CHANGING_BASH.search(command))
        case ReadTool() | HandbackTool() | OtherTool():
            return False
        case _:
            assert_never(call.tool)


def is_doc_edit(call: ToolCall) -> bool:
    match call.tool:
        case (
            EditTool(path=path)
            | WriteTool(path=path)
            | MultiEditTool(path=path)
            | NotebookEditTool(path=path)
        ):
            return path.endswith(".md")
        case BashTool() | ReadTool() | HandbackTool() | OtherTool():
            return False
        case _:
            assert_never(call.tool)


# --- Loop steps --------------------------------------------------------------

BRIEF_HEAD = 700  # briefs paste long rules after their first lines
RESEARCH_TYPES = {
    "researcher",
    "Explore",
}  # read-only by their tools, whatever the brief says
REVIEW_BRIEF = re.compile(r"(?:invoke|run)\s+(?:the\s+)?\W*pragmatic-review")
SECOND_PASS = re.compile(r"--fixes|pass[ -]2|re-review|\bsecond\b")
FIX_DESCRIPTION = re.compile(r"^(fix|final fix|address)")
DESCRIPTION_STEPS = (
    (LoopStep.FIX, FIX_DESCRIPTION),
    (LoopStep.REFACTOR, re.compile(r"^refactor")),
    (LoopStep.PR_DESCRIPTION, re.compile(r"pr[ -]description|pr #?\d* ?body")),
    (
        LoopStep.RESEARCH,
        re.compile(
            r"^(research|audit|analy[sz]e|mine|find|map|hunt|classify|triage|measure|investigate|compare)\b"
        ),
    ),
    (
        LoopStep.IMPLEMENT,
        re.compile(r"^(implement|write|add|update|apply|rewrite|port|create)\b"),
    ),
)
BRIEF_STEPS = (
    (LoopStep.REFACTOR, re.compile(r"(?:invoke|run)\s+(?:the\s+)?\W*refactor")),
    (
        LoopStep.RESEARCH,
        re.compile(r"^(research|read-only)|(?:invoke|run)\s+(?:the\s+)?\W*researcher"),
    ),
    (LoopStep.IMPLEMENT, re.compile(r"\bimplementer\b")),
)


def steps_of(session: Session) -> Iterator[tuple[Agent, LoopStep]]:
    for agent in session.subagents:
        yield agent, loop_step(step_owner(agent, session.by_id))


def step_by_id(session: Session) -> dict[AgentId, LoopStep]:
    return {a.id: step for a, step in steps_of(session)}


def step_owner(agent: Agent, by_id: dict[AgentId, Agent]) -> Agent:
    """The agent whose brief names `agent`'s step: the outermost review above it
    or itself, so a review under an orchestrator subagent stays a review, else
    itself if a research type, so research under an orchestrator subagent stays
    research, else its top-level subagent."""
    line = lineage(agent, by_id)
    own = agent if agent.kind in RESEARCH_TYPES else line[-1]
    return next((a for a in reversed(line) if loop_step(a) in REVIEW_PASSES), own)


def lineage(agent: Agent, by_id: dict[AgentId, Agent]) -> list[Agent]:
    """`agent`, then each subagent above it, outermost last."""
    line = [agent]
    while (parent := spawner(line[-1], by_id)) is not None:
        line.append(parent)
    return line


def spawner(agent: Agent, by_id: dict[AgentId, Agent]) -> Agent | None:
    """The subagent that spawned `agent`, None for one the main agent spawned."""
    return None if agent.parent is None else by_id.get(agent.parent)


def loop_step(agent: Agent) -> LoopStep:
    """The step an agent's type, else its own description and brief, name."""
    if agent.kind in RESEARCH_TYPES:
        return LoopStep.RESEARCH
    description = agent.description.lower()
    brief = brief_head(agent.brief)
    if REVIEW_BRIEF.search(brief) and not FIX_DESCRIPTION.search(description):
        return review_pass(description, brief)
    by_description = (
        step for step, pattern in DESCRIPTION_STEPS if pattern.search(description)
    )
    by_brief = (step for step, pattern in BRIEF_STEPS if pattern.search(brief))
    return next(by_description, next(by_brief, LoopStep.OTHER))


def review_pass(description: str, brief: str) -> LoopStep:
    if SECOND_PASS.search(brief) or SECOND_PASS.search(description):
        return LoopStep.REVIEW_2
    return LoopStep.FINAL_REVIEW if "final" in description else LoopStep.REVIEW_1


def brief_head(brief: str) -> str:
    return brief[:BRIEF_HEAD].lower()


def children_by_parent(session: Session) -> list[tuple[Agent, list[Agent]]]:
    """Every agent that spawned others, with its children in spawn order."""
    groups: dict[AgentId, list[Agent]] = defaultdict(list)
    for agent in session.subagents:
        groups[(spawner(agent, session.by_id) or session.main).id].append(agent)
    return [
        (session.by_id.get(key, session.main), sorted(kids, key=lambda a: a.start))
        for key, kids in groups.items()
    ]


# --- Quality modes -----------------------------------------------------------


class Mode(Enum):
    POC = "POC"
    BALANCED = "Balanced"
    MAX = "Max"


class Trivial(Enum):
    """The value is the brief's wire form: stating it either way is its own row."""

    UNSTATED = ""
    ON = ", Trivial"
    OFF = ", not Trivial"


@dataclass(frozen=True)
class Quality:
    mode: Mode
    trivial: Trivial

    @override
    def __str__(self) -> str:
        return self.mode.value + self.trivial.value


NO_QUALITY = "(none stated)"
QUALITY = re.compile(
    rf"\bQuality:\W*({'|'.join(m.value for m in Mode)})\b(, (?:not )?Trivial\b)?"
)
SWEEP_LINE = re.compile(
    r"^\W*Security: Trivial\b", re.MULTILINE
)  # the one Trivial activation with a fixed wording
UNCOUNTED_QUALITY = "Not counted: Trivial self-activated outside a review, which stays in its stated row, and a PR opened in another session or by a script."


def quality_groups(session: Session) -> dict[Quality | None, list[Agent]]:
    """The session's agents by Quality, None where no brief states one."""
    fallback = session_quality(session)
    groups: dict[Quality | None, list[Agent]] = defaultdict(list)
    for agent in session.agents:
        groups[quality_of(agent, session.by_id) or fallback].append(agent)
    return groups


def session_quality(session: Session) -> Quality | None:
    """The main agent's, which rarely states one: else what most subagents
    state, the latest on a tie, so a session that left Trivial counts as left."""
    spawned = sorted(session.subagents, key=lambda a: a.start)
    stated = [q for a in reversed(spawned) if (q := stated_quality(a.brief))]
    common = next((q for q, _ in Counter(stated).most_common(1)), None)
    return stated_quality(session.main.brief) or common


def quality_of(agent: Agent, by_id: dict[AgentId, Agent]) -> Quality | None:
    """What its brief states, else what the nearest subagent above it states."""
    return next(
        (q for a in lineage(agent, by_id) if (q := stated_quality(a.brief))), None
    )


def stated_quality(brief: str) -> Quality | None:
    found = QUALITY.search(brief)
    return (
        Quality(Mode(found.group(1)), Trivial(found.group(2) or "")) if found else None
    )


def quality_label(quality: Quality | None) -> str:
    return str(quality or NO_QUALITY)


def self_activated_trivial(session: Session) -> Iterator[Agent]:
    """Reviews that reported a Trivial sweep though nothing briefed them Trivial."""
    for quality, group in quality_groups(session).items():
        if quality is None or quality.trivial is not Trivial.ON:
            yield from (a for a in group if SWEEP_LINE.search(a.report))


def cost_per_pr(agents: list[Agent]) -> float | None:
    """None for agents that opened no PR: a follow-up session, or research."""
    opened = prs_opened(agents)
    return effective(agents) / opened if opened else None


def prs_opened(agents: list[Agent]) -> int:
    return sum(
        1
        for a in agents
        for c in a.calls
        if isinstance(c.tool, BashTool)
        and PR_CREATE.search(c.tool.command)
        and isinstance(c.outcome, Ok)
    )


# --- Reviews -----------------------------------------------------------------

RUN_BY_MAIN = "run by main"
RAISED = re.compile(r"(\d+)\s+raised,\s*(\d+)\s+survived")
SEVERITY_ROW = re.compile(
    r"^\|\s*\d+\s*\|\s*\**(Major|Minor|Nit)\**\s*\|", re.MULTILINE | re.IGNORECASE
)
SEVERITY_LINE = re.compile(
    r"^\s*severity\s+(major|minor|nit)\b", re.MULTILINE | re.IGNORECASE
)
VERDICT_LINE = re.compile(
    r"^\s*verdict\s+(met|not met|unverified)\b", re.MULTILINE | re.IGNORECASE
)
REVIEW_ROLES = (
    ("requirement", re.compile(r"requirement|\breq\b")),
    ("blockers DEEP", re.compile(r"blockers?\b.*\bdeep\b|\bdeep\b.*\bblockers?")),
    ("blockers", re.compile(r"blocker")),
    ("regressions", re.compile(r"regression")),
    ("house rules", re.compile(r"house|scream")),
    ("tests", re.compile(r"\btests?\b")),
)


def review_runs(session: Session) -> Iterator[ReviewRun]:
    for agent, step in steps_of(session):
        if step in REVIEW_PASSES and step_owner(agent, session.by_id) is agent:
            tree = [
                a for a in session.subagents if step_owner(a, session.by_id) is agent
            ]
            yield ReviewRun(
                ByAgent(step, total(a.usage for a in tree)), parse_review(agent.report)
            )
    for text in session.main.texts:
        if RAISED.search(text) or SEVERITY_ROW.search(text):
            yield ReviewRun(ByMain(), parse_review(text))


def parse_review(report: str) -> Review:
    arithmetic = RAISED.search(report)
    severities = tally(SEVERITY_ROW, report)
    if arithmetic is None:
        return Unparsed(severities["major"], severities["minor"], severities["nit"])
    return ParsedReview(
        raised=int(arithmetic.group(1)),
        survived=int(arithmetic.group(2)),
        major=severities["major"],
        minor=severities["minor"],
        nit=severities["nit"],
        met=len(re.findall(r"✅\s*\**Met", report)),
        not_met=len(re.findall(r"❌\s*\**Not met", report)),
        unverified=len(re.findall(r"⚠️\s*\**Unverified", report)),
        do_not_merge=report.count("Do not merge"),
    )


def tally(pattern: re.Pattern[str], text: str) -> Counter[str]:
    return Counter(found.lower() for found in captures(pattern, text))


def inner_reviewers(session: Session) -> Iterator[Agent]:
    """The agents a review agent spawned."""
    for agent, step in steps_of(session):
        if step in REVIEW_PASSES and step_owner(agent, session.by_id) is not agent:
            yield agent


def review_role(agent: Agent) -> str:
    texts = (agent.description.lower(), brief_head(agent.brief))
    return next(
        (
            role
            for text in texts
            for role, pattern in REVIEW_ROLES
            if pattern.search(text)
        ),
        "other",
    )


# --- Cache rewrites ----------------------------------------------------------


class Wait(Enum):
    """What the agent was doing while its cache expired."""

    BASH = "foreground Bash"
    AGENT = "Agent"
    IDLE = "idle"


@dataclass(frozen=True)
class Rewrite:
    cost: float
    wait: Wait


def cache_rewrites(agent: Agent) -> Iterator[Rewrite]:
    """Each call that wrote most of its context back after its cache expired."""
    life = MAIN_CACHE_LIFE if agent.kind == "main" else SUBAGENT_CACHE_LIFE
    for before, response in pairwise(agent.responses):
        usage = response.usage
        if (
            response.at - before.at > life
            and usage.cache_creation > usage.context * REWRITE_SHARE
        ):
            yield Rewrite(
                usage.cache_creation * CACHE_WRITE_WEIGHT, wait_of(before.calls)
            )


def wait_of(calls: list[ToolCall]) -> Wait:
    """The wait behind a gap, from the calls of the response before it."""
    if any(c.name in SPAWN for c in calls):
        return Wait.AGENT
    if any(isinstance(c.timing, Foreground) for c, _ in bash_runs(calls)):
        return Wait.BASH
    return Wait.IDLE


# --- Agent communication -----------------------------------------------------

SPAWN = {"Agent", "Task"}
FOLLOW_UP = "SendMessage"
HANDBACK_WORDS = 300  # the hand-back limit agents are told to keep to
THIN_WORDS = 20  # too short to carry a result: a stall, or an empty return
CHARS_PER_TOKEN = 4
NOTES_FILE = re.compile(r"/tmp/\S+\.md\b")  # noqa: S108 - matches paths, creates none
FILE_NAME = re.compile(r"[\w.+/-]+\.[A-Za-z]\w{0,7}\b")
DIFF_COMMANDS = {"git diff", "git show"}
READ_COMMANDS = DIFF_COMMANDS | {
    "cat",
    "sed",
    "head",
    "tail",
    "nl",
    "rg",
    "grep",
    "ls",
    "wc",
    "awk",
    "jq",
    "sort",
    "uniq",
    "cut",
    "tr",
    "stat",
    "file",
    "diff",
    "tree",
    "echo",
    "printf",
    "true",
    "git log",
    "git status",
    "git blame",
    "git grep",
    "git ls-files",
    "git rev-parse",
    "gh pr view",
    "gh pr diff",
    "gh run view",
    "gh issue view",
}
OUTPUT_REDIRECT = re.compile(r">>?(?!>|\s*&|\s*/dev/null\b)")


def follow_ups(session: Session) -> Iterator[FollowUp]:
    steps = step_by_id(session)
    for parent, children in children_by_parent(session):
        groups: dict[AgentId, list[ToolCall]] = defaultdict(list)
        for child, call in calls_after_handbacks(parent, children):
            groups[child.id].append(call)
        for child in children:
            calls = groups[child.id]
            named = file_names(child.report)
            rereads = [c for c in calls if read_files(c) & named or is_diff(c)]
            yield FollowUp(
                steps[child.id],
                rereads,
                [c for c, command in bash_runs(calls) if check_key(command)],
            )


def calls_after_handbacks(
    parent: Agent, children: list[Agent]
) -> Iterator[tuple[Agent, ToolCall]]:
    """The parent's calls between a child's hand-back and its next spawn, each
    attributed to the child that finished last before it."""
    spawns = [c.start for c in parent.calls if c.name in SPAWN]
    for call in parent.calls:
        ended = [a for a in children if a.end <= call.start]
        if ended and call.name not in SPAWN:
            child = max(ended, key=lambda a: a.end)
            if not any(child.end <= spawn < call.start for spawn in spawns):
                yield child, call


def is_diff(call: ToolCall) -> bool:
    command = call.command
    return (
        command is not None
        and any(s.name in DIFF_COMMANDS for s in steps(command))
        and not is_edit(call)
    )


def read_files(call: ToolCall) -> set[str]:
    """The file names a read-only call looked at."""
    match call.tool:
        case ReadTool(path=path):
            return {Path(path).name}
        case BashTool(command=command) if is_read_only(call):
            return file_names(command)
        case (
            BashTool()
            | EditTool()
            | WriteTool()
            | MultiEditTool()
            | NotebookEditTool()
            | HandbackTool()
            | OtherTool()
        ):
            return set()
        case _:
            assert_never(call.tool)


def file_names(text: str) -> set[str]:
    return {Path(found.group()).name for found in FILE_NAME.finditer(text)}


def is_read_only(call: ToolCall) -> bool:
    match call.tool:
        case ReadTool():
            return True
        case BashTool(command=command):
            found = steps(command)
            reads = bool(found) and all(s.name in READ_COMMANDS for s in found)
            return reads and not OUTPUT_REDIRECT.search(command) and not is_edit(call)
        case (
            EditTool()
            | WriteTool()
            | MultiEditTool()
            | NotebookEditTool()
            | HandbackTool()
            | OtherTool()
        ):
            return False
        case _:
            assert_never(call.tool)


def spawned_again(session: Session) -> Iterator[LoopStep]:
    """The step of each spawn that repeats the step of the hand-back right before it."""
    steps = step_by_id(session)
    for _, children in children_by_parent(session):
        for first, second in pairwise(children):
            if steps[first.id] == steps[second.id] and second.start >= first.end:
                yield steps[second.id]


def resent_tokens(report: str, ended: float, parent_calls: list[ToolCall]) -> int:
    """About what a hand-back costs: its tokens, sent again on every later parent call."""
    later = sum(1 for c in parent_calls if c.start >= ended)
    return len(report) // CHARS_PER_TOKEN * later


def repeated_reads(session: Session) -> list[RepeatedRead]:
    groups: dict[tuple[str, ReadBound, ReadBound], list[tuple[Agent, ToolCall]]] = (
        defaultdict(list)
    )
    for agent in session.agents:
        for call in filter(is_read_only, agent.calls):
            groups[(what(call), *read_window(call.tool))].append((agent, call))
    out: list[RepeatedRead] = []
    for (name, *_), runs in groups.items():
        agents = {agent.id for agent, _ in runs}
        sizes = sorted(call.result_chars for _, call in runs)
        if len(agents) > 1:
            out.append(RepeatedRead(name, len(agents), len(runs), sum(sizes[:-1])))
    return out


def read_window(tool: Tool) -> tuple[ReadBound, ReadBound]:
    match tool:
        case ReadTool(offset=offset, limit=limit):
            return offset, limit
        case (
            BashTool()
            | EditTool()
            | WriteTool()
            | MultiEditTool()
            | NotebookEditTool()
            | HandbackTool()
            | OtherTool()
        ):
            return None, None
        case _:
            assert_never(tool)


def research_overlaps(session: Session) -> Iterator[set[str]]:
    """For each implementer, the files it read that an earlier research agent read."""
    steps = list(steps_of(session))
    research = [a for a, step in steps if step == LoopStep.RESEARCH]
    for agent, step in steps:
        if step == LoopStep.IMPLEMENT:
            explored = {
                name
                for a in research
                if a.end <= agent.start
                for c in a.calls
                for name in read_files(c)
            }
            overlap = {name for c in agent.calls for name in read_files(c)} & explored
            if overlap:
                yield overlap


# --- Rendering ---------------------------------------------------------------


def render(window: Window, scope: str, split: datetime | None) -> str:
    sessions = window.sessions
    agents = [(s, a) for s in sessions for a in s.agents]
    calls = [(s, a, c) for s, a in agents for c in a.calls]
    sections = [
        f"# Session report ({scope})",
        summary(sessions),
        sessions_table(sessions),
        agent_types(agents),
        startup_sizes([a for _, a in agents]),
        costliest_agents(agents),
        skills(agents),
        quality_costs(sessions),
        loop_steps(sessions),
        cache_rewrites_section(sessions),
        review_yield(sessions),
        after_handback(sessions),
        communication(sessions),
        largest_results(calls),
        tool_times(calls),
        bash_commands(calls),
        checks_section(sessions),
        polling(calls),
        failures(calls),
        *([compare(sessions, split)] if split else []),
    ]
    return "\n\n".join(sections) + "\n"


def summary(sessions: list[Session]) -> str:
    wall = sum(s.wall for s in sessions)
    wait = sum(s.human_wait for s in sessions)
    main = total(s.main.usage for s in sessions)
    subs = total(a.usage for s in sessions for a in s.subagents)
    calls = sum(len(a.responses) for s in sessions for a in s.agents)
    cost = f"main {kilo(main.effective)}, subagents {kilo(subs.effective)}"
    return "\n".join(
        [
            f"- Sessions: {len(sessions)}, agents: {sum(len(s.agents) for s in sessions)}, API calls: {calls}",
            f"- Wall clock: {hours(wall)} = work {hours(wall - wait)} + waiting on the person {hours(wait)}",
            f"- Tokens (in/cache read/cache write/out): main {tokens(main)}, subagents {tokens(subs)}",
            f"- Effective cost ({WEIGHTS}): {kilo(main.effective + subs.effective)} = {cost}",
        ]
    )


def sessions_table(sessions: list[Session]) -> str:
    ranked = sorted(sessions, key=lambda s: -effective(s.agents))
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
            kilo(effective(s.agents)),
        ]
        for s in ranked[:12]
    ]
    header = [
        "session",
        "project",
        "start",
        "wall",
        "waiting",
        "commands",
        "main tokens",
        "main peak",
        "subagent tokens",
        "subagents",
        "effective",
    ]
    return section("Sessions, costliest first", header, rows, len(ranked))


def agent_types(agents: list[tuple[Session, Agent]]) -> str:
    groups: dict[str, list[Agent]] = defaultdict(list)
    for _, agent in agents:
        groups[agent.kind].append(agent)
    ranked = sorted(groups.items(), key=lambda kv: -effective(kv[1]))
    rows = [
        [
            kind,
            str(len(group)),
            str(sum(len(a.responses) for a in group)),
            tokens(total(a.usage for a in group)),
            kilo(max(a.peak_context for a in group)),
            kilo(effective(group)),
        ]
        for kind, group in ranked
    ]
    return section(
        "Tokens by agent type",
        ["type", "agents", "API calls", "tokens", "peak context", "effective"],
        rows,
        len(rows),
    )


def startup_sizes(agents: list[Agent]) -> str:
    groups: dict[str, list[Agent]] = defaultdict(list)
    for agent in agents:
        if agent.first_context:
            groups[agent.kind].append(agent)
    ranked = sorted(groups.items(), key=lambda kv: -len(kv[1]))
    rows = [
        [kind, str(len(group)), *startup_cells(group)] for kind, group in ranked[:TOP]
    ]
    header = ["type", "n", "p50", "p90", "instructions", "skill listing", "remainder"]
    return section(
        "Start-up size: first-call context, parts at p50 (chars / 4)",
        header,
        rows,
        len(ranked),
    )


def startup_cells(group: list[Agent]) -> list[str]:
    contexts = [a.first_context for a in group]
    instructions = [a.instruction_chars // CHARS_PER_TOKEN for a in group]
    listings = [a.listing_chars // CHARS_PER_TOKEN for a in group]
    remainders = [
        context - instruction - listing
        for context, instruction, listing in zip(
            contexts, instructions, listings, strict=True
        )
    ]
    return [
        kilo(p)
        for p in (
            statistics.median(contexts),
            percentile(contexts, 0.9),
            *map(statistics.median, (instructions, listings, remainders)),
        )
    ]


def percentile(values: list[int], share: float) -> int:
    """Nearest rank, so the value is one that happened."""
    return sorted(values)[math.ceil(share * len(values)) - 1]


def costliest_agents(agents: list[tuple[Session, Agent]]) -> str:
    subs = sorted(
        ((s, a) for s, a in agents if a.kind != "main"),
        key=lambda sa: -sa[1].usage.effective,
    )
    rows = [
        [
            s.id[:8],
            a.kind,
            clip(a.description, 50),
            tokens(a.usage),
            kilo(a.peak_context),
            str(len(a.responses)),
            kilo(a.usage.effective),
        ]
        for s, a in subs[:TOP]
    ]
    return section(
        "Costliest subagents",
        [
            "session",
            "type",
            "description",
            "tokens",
            "peak context",
            "API calls",
            "effective",
        ],
        rows,
        len(subs),
    )


def skills(agents: list[tuple[Session, Agent]]) -> str:
    groups: dict[str, list[Response]] = defaultdict(list)
    for _, agent in agents:
        for r in agent.responses:
            groups[r.skill or "(none)"].append(r)
    ranked = sorted(groups.items(), key=lambda kv: -sum(r.usage.context for r in kv[1]))
    rows = [
        [skill, str(len(rs)), tokens(total(r.usage for r in rs))]
        for skill, rs in ranked[:TOP]
    ]
    return section(
        "Tokens by skill (attributionSkill)",
        ["skill", "API calls", "tokens"],
        rows,
        len(ranked),
    )


def quality_costs(sessions: list[Session]) -> str:
    groups: dict[Quality | None, list[list[Agent]]] = defaultdict(list)
    for s in sessions:
        for quality, group in quality_groups(s).items():
            groups[quality].append(group)
    ranked = sorted(groups.items(), key=lambda kv: -sum(effective(g) for g in kv[1]))
    rows = [
        [quality_label(quality), *quality_cells(parts)] for quality, parts in ranked
    ]
    header = ["mode", "sessions", "PRs", "agents", "effective", "per PR, median"]
    activated = [a for s in sessions for a in self_activated_trivial(s)]
    counted = f"Reviews that activated Trivial themselves: {len(activated)}, {kilo(effective(activated))} effective."
    return f"{section('Cost by Quality mode', header, rows, len(rows))}\n\n{counted} {UNCOUNTED_QUALITY}"


def quality_cells(parts: list[list[Agent]]) -> list[str]:
    agents = [a for part in parts for a in part]
    per_pr = [cost for part in parts if (cost := cost_per_pr(part)) is not None]
    median = kilo(statistics.median(per_pr)) if per_pr else "-"
    return [
        str(len(parts)),
        str(prs_opened(agents)),
        str(len(agents)),
        kilo(effective(agents)),
        median,
    ]


def loop_steps(sessions: list[Session]) -> str:
    groups: dict[LoopStep, list[tuple[Session, Agent]]] = defaultdict(list)
    for s in sessions:
        groups[LoopStep.ORCHESTRATOR].append((s, s.main))
        for agent, step in steps_of(s):
            groups[step].append((s, agent))
    ranked = sorted(groups.items(), key=lambda kv: -effective(a for _, a in kv[1]))
    rows = [
        [
            step.value,
            str(len(group)),
            str(len({s.id for s, _ in group})),
            tokens(total(a.usage for _, a in group)),
            minutes(sum(a.wall for _, a in group)),
            kilo(effective(a for _, a in group)),
        ]
        for step, group in ranked
    ]
    return section(
        "Loop steps",
        ["step", "agents", "sessions", "tokens", "agent wall", "effective"],
        rows,
        len(rows),
    )


def cache_rewrites_section(sessions: list[Session]) -> str:
    agents = [(s, a) for s in sessions for a in s.agents]
    rewriters = [(s, a, found) for s, a in agents if (found := list(cache_rewrites(a)))]
    rewrites = [r for _, _, group in rewriters for r in group]
    spent = effective(a for _, a in agents)
    cost = sum(r.cost for r in rewrites)
    share = f"{100 * cost / spent:.0f}%" if spent else "0%"
    by_wait = [
        [wait.value, *rewrite_cells([r for r in rewrites if r.wait is wait])]
        for wait in Wait
    ]
    ranked = sorted(rewriters, key=lambda rewriter: -sum(r.cost for r in rewriter[2]))
    by_agent = [
        [s.id[:8], a.kind, clip(a.description, 50), *rewrite_cells(group)]
        for s, a, group in ranked[:TOP_REWRITERS]
    ]
    return "\n\n".join(
        [
            section(
                "Cache rewrites",
                ["waiting on", "rewrites", "effective"],
                by_wait,
                len(by_wait),
            ),
            f"{len(rewrites)} rewrites, {kilo(cost)} effective, {share} of the total.",
            table(["session", "type", "description", "rewrites", "effective"], by_agent)
            + omitted(len(ranked), len(by_agent)),
        ]
    )


def rewrite_cells(rewrites: list[Rewrite]) -> list[str]:
    return [str(len(rewrites)), kilo(sum(r.cost for r in rewrites))]


def review_yield(sessions: list[Session]) -> str:
    runs = [r for s in sessions for r in review_runs(s)]
    counts = [f.name for f in fields(ParsedReview)]
    rows: list[list[str]] = []
    for name in [*(step.value for step in REVIEW_PASSES), RUN_BY_MAIN]:
        group = [r for r in runs if pass_name(r.source) == name]
        if group:
            sums = [
                str(sum(getattr(review_counts(r.review), count) for r in group))
                for count in counts
            ]
            unparsed = sum(1 for r in group if isinstance(r.review, Unparsed))
            rows.append(
                [
                    name,
                    str(len(group)),
                    review_tokens(r.source for r in group),
                    *sums,
                    str(unparsed),
                ]
            )
    header = [
        "pass",
        "reports",
        "tokens",
        *(c.replace("_", " ") for c in counts),
        "unparsed",
    ]
    return (
        section("Review yield", header, rows, len(rows))
        + "\n\nBy review agent type, before judging:\n\n"
        + inner_yield(sessions)
    )


def review_counts(review: Review) -> ParsedReview:
    """Every count of a report, 0 for what an unparsed one does not carry."""
    match review:
        case ParsedReview():
            return review
        case Unparsed(major, minor, nit):
            return ParsedReview(
                raised=0,
                survived=0,
                major=major,
                minor=minor,
                nit=nit,
                met=0,
                not_met=0,
                unverified=0,
                do_not_merge=0,
            )


def pass_name(source: ReviewSource) -> str:
    match source:
        case ByAgent(step, _):
            return step.value
        case ByMain():
            return RUN_BY_MAIN


def review_tokens(sources: Iterable[ReviewSource]) -> str:
    usages = [s.usage for s in sources if isinstance(s, ByAgent)]
    return tokens(total(usages)) if usages else "-"


def inner_yield(sessions: list[Session]) -> str:
    groups: dict[str, list[Agent]] = defaultdict(list)
    for s in sessions:
        for agent in inner_reviewers(s):
            groups[review_role(agent)].append(agent)
    rows: list[list[str]] = []
    for role, group in sorted(
        groups.items(), key=lambda kv: -sum(a.usage.context for a in kv[1])
    ):
        found = [tally(SEVERITY_LINE, a.report) for a in group]
        verdicts = tally(VERDICT_LINE, "\n".join(a.report for a in group))
        by_severity = [
            str(sum(f[severity] for f in found))
            for severity in ("major", "minor", "nit")
        ]
        rows.append(
            [
                role,
                str(len(group)),
                tokens(total(a.usage for a in group)),
                *by_severity,
                str(sum(1 for f in found if f)),
                str(verdicts["not met"]),
                str(verdicts["unverified"]),
            ]
        )
    return table(
        [
            "agent",
            "runs",
            "tokens",
            "major",
            "minor",
            "nit",
            "runs with a finding",
            "not met",
            "unverified",
        ],
        rows,
    )


def after_handback(sessions: list[Session]) -> str:
    readied = [(s, first_ready(s)) for s in sessions]
    later = [
        [p for p in s.prompts if p.at > ready]
        for s, ready in readied
        if ready is not None
    ]
    prompts = [p for group in later for p in group]
    commands = Counter(c for p in prompts for c in p.commands)
    named = "".join(f", /{name} {n}" for name, n in commands.most_common())
    free_text = sum(1 for p in prompts if not p.commands)
    return "\n".join(
        [
            "## After hand-back",
            "",
            f"- Sessions that ran `gh pr ready`: {len(later)}, with a human prompt after it: {sum(1 for group in later if group)}",
            f"- Human prompts after it: {len(prompts)}: {free_text} free text{named}",
        ]
    )


def first_ready(session: Session) -> float | None:
    readied = [
        c.start
        for a in session.agents
        for c, command in bash_runs(a.calls)
        if PR_READY.search(command)
    ]
    return min(readied, default=None)


def communication(sessions: list[Session]) -> str:
    return "\n\n".join(
        [
            "## Agent communication",
            brief_sizes(sessions),
            handback_table(sessions),
            communication_lines(sessions),
            repeated_table(sessions),
        ]
    )


def brief_sizes(sessions: list[Session]) -> str:
    groups: dict[tuple[str, LoopStep], list[Agent]] = defaultdict(list)
    for s in sessions:
        for agent, step in steps_of(s):
            groups[(agent.kind, step)].append(agent)
    ranked = sorted(groups.items(), key=lambda kv: -sum(words(a.report) for a in kv[1]))
    rows: list[list[str]] = []
    for (kind, step), group in ranked[:TOP]:
        briefs = [words(a.brief) for a in group]
        reports = [words(a.report) for a in group]
        over = sum(1 for n in reports if n > HANDBACK_WORDS)
        thin = sum(1 for n in reports if n < THIN_WORDS)
        rows.append(
            [
                kind,
                step.value,
                str(len(group)),
                f"{statistics.median(briefs):.0f}",
                str(max(briefs)),
                f"{statistics.median(reports):.0f}",
                str(max(reports)),
                str(over),
                str(thin),
            ]
        )
    header = [
        "type",
        "step",
        "agents",
        "brief words",
        "max",
        "hand-back words",
        "max",
        f"over {HANDBACK_WORDS}",
        f"under {THIN_WORDS}",
    ]
    return (
        "Brief and hand-back size (medians):\n\n"
        + table(header, rows)
        + omitted(len(ranked), len(rows))
    )


def handback_table(sessions: list[Session]) -> str:
    groups: dict[LoopStep, list[FollowUp]] = defaultdict(list)
    for s in sessions:
        for follow_up in follow_ups(s):
            groups[follow_up.step].append(follow_up)
    again = Counter(step for s in sessions for step in spawned_again(s))
    rows: list[list[str]] = []
    for step, group in sorted(
        groups.items(),
        key=lambda kv: -sum(c.result_chars for f in kv[1] for c in f.rereads),
    ):
        rereads = [c for f in group for c in f.rereads]
        reverifies = [c for f in group for c in f.reverifies]
        rows.append(
            [
                step.value,
                str(len(group)),
                str(len(rereads)),
                kilo(sum(c.result_chars for c in rereads)),
                str(len(reverifies)),
                minutes(sum(c.seconds or 0 for c in reverifies)),
                str(again[step]),
            ]
        )
    header = [
        "step",
        "hand-backs",
        "re-reads",
        "re-read chars",
        "re-verifies",
        "re-verify time",
        "spawned again",
    ]
    return "What parents did after a hand-back, before their next spawn:\n\n" + table(
        header, rows
    )


def communication_lines(sessions: list[Session]) -> str:
    handed = [
        (parent, child)
        for s in sessions
        for parent, children in children_by_parent(s)
        for child in children
    ]
    large = [
        (parent, child)
        for parent, child in handed
        if words(child.report) > HANDBACK_WORDS
    ]
    notes = sum(1 for _, child in handed if NOTES_FILE.search(child.report))
    messages = [
        c for s in sessions for a in s.agents for c in a.calls if c.name == FOLLOW_UP
    ]
    overlaps = [overlap for s in sessions for overlap in research_overlaps(s)]
    return "\n".join(
        [
            f"- Hand-backs over {HANDBACK_WORDS} words: {len(large)}, {kilo(sum(len(c.report) for _, c in large))} chars, about {kilo(sum(resent_tokens(c.report, c.end, p.calls) for p, c in large))} tokens sent again on later parent calls",
            f"- Hand-backs pointing at a notes file: {notes}",
            f"- Follow-up messages to a subagent: {len(messages)}",
            f"- Implementers reading files a research agent read: {len(overlaps)}, {sum(len(o) for o in overlaps)} files between them",
        ]
    )


def repeated_table(sessions: list[Session]) -> str:
    found = [(s.id[:8], r) for s in sessions for r in repeated_reads(s)]
    ranked = sorted(found, key=lambda sr: -sr[1].repeated_chars)
    rows = [
        [sid, clip(r.what, 60), str(r.agents), str(r.runs), kilo(r.repeated_chars)]
        for sid, r in ranked[:TOP]
    ]
    head = f"Same read or read-only command by two or more agents of a session: {len(found)}, {kilo(sum(r.repeated_chars for _, r in found))} chars repeated."
    return (
        head
        + "\n\n"
        + table(["session", "what", "agents", "runs", "chars after the first"], rows)
        + omitted(len(ranked), len(rows))
    )


def largest_results(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    ranked = sorted(calls, key=lambda sac: -sac[2].result_chars)
    rows = [
        [kilo(c.result_chars), c.name, s.id[:8], a.kind, clip(what(c), 50)]
        for s, a, c in ranked[:TOP]
    ]
    images = [c for _, _, c in calls if c.images]
    table = section(
        "Largest tool results (chars)",
        ["chars", "tool", "session", "agent", "what"],
        rows,
        len(ranked),
    )
    return (
        table
        + f"\n\nImages in tool results: {sum(c.images for c in images)} across {len(images)} calls."
    )


def what(call: ToolCall) -> str:
    return " ".join(subject(call.tool).split())


def subject(tool: Tool) -> str:
    match tool:
        case BashTool(command=command):
            return command
        case (
            ReadTool(path=path)
            | EditTool(path=path)
            | WriteTool(path=path)
            | MultiEditTool(path=path)
            | NotebookEditTool(path=path)
        ):
            return path
        case HandbackTool():
            return ""
        case OtherTool(label=label):
            return label or ""
        case _:
            assert_never(tool)


def tool_times(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    groups: dict[tuple[str, str], list[float]] = defaultdict(list)
    for _, _, c in calls:
        if (
            c.seconds is not None and c.name != ASK
        ):  # waiting on the person is never a bottleneck
            groups[(c.name, c.mode)].append(c.seconds)
    ranked = sorted(groups.items(), key=lambda kv: -sum(kv[1]))
    rows = [
        [
            name,
            mode,
            str(len(ts)),
            minutes(sum(ts)),
            f"{statistics.median(ts):.0f}s",
            f"{max(ts):.0f}s",
        ]
        for (name, mode), ts in ranked[:12]
    ]
    return section(
        "Wall time per tool",
        ["tool", "mode", "calls", "total", "median", "max"],
        rows,
        len(ranked),
    )


def bash_commands(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    groups: dict[str, list[ToolCall]] = defaultdict(list)
    for c, command in bash_runs(c for _, _, c in calls):
        if c.seconds is not None:
            groups[label(command)].append(c)
    ranked = sorted(groups.items(), key=lambda kv: -sum(c.seconds or 0 for c in kv[1]))
    rows: list[list[str]] = []
    for name, cs in ranked[:12]:
        fg = [c.seconds or 0 for c in cs if c.mode == "fg"]
        bg = [c.seconds or 0 for c in cs if c.mode == "bg"]
        failed = sum(1 for c in cs if isinstance(c.outcome, Failed))
        rows.append(
            [
                clip(name, 60),
                str(len(fg)),
                minutes(sum(fg)),
                str(len(bg)),
                minutes(sum(bg)),
                f"{max(fg + bg):.0f}s",
                str(failed),
            ]
        )
    header = ["command", "fg calls", "fg time", "bg calls", "bg time", "max", "failed"]
    return section("Wall time per Bash command", header, rows, len(ranked))


def checks_section(sessions: list[Session]) -> str:
    reruns: list[Rerun] = []
    chains: list[Chain] = []
    for s in sessions:
        r, c = check_waste(s)
        reruns += r
        chains += c
    rerun_rows = [
        [x.session[:8], x.agent, clip(x.command, 60), x.reason, f"{x.seconds:.0f}s"]
        for x in sorted(reruns, key=lambda x: -x.seconds)[:8]
    ]
    chain_rows = [
        [x.session[:8], x.agent, clip(x.step, 60), f"{x.seconds:.0f}s"]
        for x in sorted(chains, key=lambda x: -x.seconds)[:8]
    ]
    return "\n\n".join(
        [
            f"## Redundant checks\n\nReruns with nothing changed since the same check: {len(reruns)}, {minutes(sum(x.seconds for x in reruns))}.",
            table(
                ["session", "agent", "command", "since last run", "time"], rerun_rows
            ),
            f"Build/test steps run before a full check with no edit between: {len(chains)}, {minutes(sum(x.seconds for x in chains))}.",
            table(["session", "agent", "step", "time"], chain_rows),
        ]
    )


def polling(calls: list[tuple[Session, Agent, ToolCall]]) -> str:
    bash = [(s, a, c, cmd) for s, a, c in calls if (cmd := c.command) is not None]
    loops = [c for _, _, c, command in bash if SLEEP_LOOP.search(command)]
    fg_loops = [c for c in loops if c.mode == "fg"]
    timeouts = [
        c
        for c in fg_loops
        if isinstance(c.outcome, Failed) and "timed out" in c.outcome.signature.lower()
    ]
    per_agent = Counter(
        (s.id[:8], a.kind)
        for s, a, _, command in bash
        if PR_CHECKS.search(command) and "--watch" not in command
    )
    repeated = [
        f"{sid} {kind}: {n}"
        for (sid, kind), n in per_agent.most_common(5)
        if n > ROUTINE_POLLS
    ]
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
            name = "" if c.command is None else label(c.command)
            groups[(c.name, name, c.outcome.signature)].append(c)
            missing.update(MISSING_TOOL.findall(c.outcome.signature))
    ranked = sorted(groups.items(), key=lambda kv: -len(kv[1]))
    rows = [
        [
            str(len(cs)),
            tool,
            clip(name, 40) or "-",
            ",".join(
                sorted(
                    {
                        str(c.outcome.exit_code)
                        for c in cs
                        if isinstance(c.outcome, Failed)
                        and c.outcome.exit_code is not None
                    }
                )
            )
            or "-",
            clip(sig, 80),
        ]
        for (tool, name, sig), cs in ranked[:12]
    ]
    total = sum(len(cs) for cs in groups.values())
    head = f"## Failing tool calls\n\n{total} failed calls in {len(groups)} groups. Missing tools: {', '.join(f'{t} ({n})' for t, n in missing.most_common(8)) or 'none'}."
    return (
        head
        + "\n\n"
        + table(["count", "tool", "command", "exit", "error"], rows)
        + omitted(len(ranked), len(rows))
    )


def compare(sessions: list[Session], split: datetime) -> str:
    at = split.timestamp()
    before = measures([s for s in sessions if s.start < at])
    after = measures([s for s in sessions if s.start >= at])
    ranked = sorted(
        before.keys() | after.keys(),
        key=lambda name: (-len(before[name]) - len(after[name]), name),
    )
    rows = [
        [name, *median_cells(before[name]), *median_cells(after[name])]
        for name in ranked[:TOP]
    ]
    head = f"Sessions by their start. A median needs n >= {MIN_COMPARE_N} on its side. The sides ran different tasks: a lead, never a verdict."
    return (
        f"## Before and after {fmt_time(at)}\n\n{head}\n\n"
        + table(["measure", "n before", "before", "n after", "after"], rows)
        + omitted(len(ranked), len(rows))
    )


def measures(sessions: list[Session]) -> defaultdict[str, list[float]]:
    out: defaultdict[str, list[float]] = defaultdict(list)
    for s in sessions:
        out["effective per session"].append(effective(s.agents))
        for quality, group in quality_groups(s).items():
            cost = cost_per_pr(group)
            if cost is not None:
                out[f"effective per PR, {quality_label(quality)}"].append(cost)
        for agent in s.agents:
            if agent.first_context:
                out[f"first-call context, {agent.kind}"].append(agent.first_context)
    return out


def median_cells(values: list[float]) -> list[str]:
    enough = len(values) >= MIN_COMPARE_N
    return [
        str(len(values)),
        kilo(statistics.median(values)) if enough else "not enough data",
    ]


# --- Formatting --------------------------------------------------------------


def section(title: str, header: list[str], rows: list[list[str]], total: int) -> str:
    return f"## {title}\n\n" + table(header, rows) + omitted(total, len(rows))


def table(header: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "(none)"
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(
        lines + ["| " + " | ".join(escape_cell(v) for v in row) + " |" for row in rows]
    )


def escape_cell(value: str) -> str:
    return value.replace("|", "\\|")


def omitted(total: int, shown: int) -> str:
    return f"\n\n{total - shown} more omitted." if total > shown else ""


def tokens(u: Usage) -> str:
    return "/".join(
        kilo(n) for n in (u.input, u.cache_read, u.cache_creation, u.output)
    )


MILLION = 1e6
THOUSAND = 1e3


def kilo(n: float) -> str:
    return (
        f"{n / MILLION:.1f}M"
        if n >= MILLION
        else f"{n / THOUSAND:.0f}k"
        if n >= THOUSAND
        else str(round(n))
    )


def minutes(seconds: float) -> str:
    return f"{seconds / 60:.0f}m"


def hours(seconds: float) -> str:
    return f"{seconds / 3600:.1f}h"


def fmt_time(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%d %H:%M")


def words(text: str) -> int:
    return len(text.split())


def clip(text: str, n: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


if __name__ == "__main__":
    main()
