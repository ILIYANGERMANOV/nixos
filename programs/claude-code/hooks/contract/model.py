"""A scripted stand-in for the Anthropic Messages API, so `probe.py` drives the
real `claude` client offline and the same way every run.

It answers `POST /v1/messages` with one streamed turn
(https://docs.anthropic.com/en/api/messages-streaming), picked by who asks
(the lead, the probe's subagent or the compactor) and how many turns that
conversation already holds. A request it has no turn for gets a 400 naming it,
which `claude` reports and exits on, where a 500 would be retried until timeout.
"""

import json
import threading
from dataclasses import dataclass
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast, override

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

# The probe puts it in its subagent's prompt, which Claude Code sends as that
# subagent's system prompt: the one way to tell its requests from the lead's.
SUBAGENT_MARKER = "HOOK-PROBE-SUBAGENT"
SUBAGENT_TYPE = "probe"

# The probe's hook rewrites three inputs, each leaving its tag where the
# next request shows the client honoured the rewrite.
ORIGINAL_COMMAND = "echo ORIGINAL"
REWRITE_TAG = "REWRITTEN"
SPAWN_TAG = "SPAWN-TAG"
HANDBACK_TAG = "HANDBACK-TAG"
WITNESSES = (REWRITE_TAG, SPAWN_TAG, HANDBACK_TAG)
HANDBACK_MESSAGE = "PROBE-HANDBACK"


class Speaker(Enum):
    LEAD = "lead"
    SUBAGENT = "subagent"
    COMPACT = "compact"
    # Auto mode's safety classifier, asked before a call no rule allows.
    CLASSIFIER = "classifier"


@dataclass(frozen=True, slots=True)
class Text:
    text: str


@dataclass(frozen=True, slots=True)
class ToolUse:
    name: str
    input: dict[str, Json]


type Turn = Text | ToolUse


@dataclass(frozen=True, slots=True)
class Unscripted:
    """A request past its speaker's script: a newer client asks for more."""

    speaker: Speaker
    step: int


def bash(command: str) -> ToolUse:
    return ToolUse("Bash", {"command": command, "description": command})


# The two conversations, one turn per request. Each Bash call is one the
# probe's settings allow, and the lead spawns in the foreground, so the run
# needs no permission prompt and ends when the lead does.
SCRIPTS: dict[Speaker, tuple[Turn, ...]] = {
    Speaker.LEAD: (
        bash(ORIGINAL_COMMAND),
        bash("cd sub"),
        bash("pwd"),
        ToolUse(
            "Agent",
            {
                "subagent_type": SUBAGENT_TYPE,
                "description": "Probe the subagent's hooks",
                "prompt": "Run the probe.",
                "run_in_background": False,
            },
        ),
        Text("LEAD-DONE"),
    ),
    Speaker.SUBAGENT: (
        bash("pwd"),
        bash("cd .."),
        bash("pwd"),
        ToolUse("SubagentHandback", {"message": HANDBACK_MESSAGE}),
    ),
}

# Auto mode's classifier reads a severity below 50 as allow.
ALLOW = Text("<severity>0</severity>")
SUMMARY = Text("<summary>The probe ran.</summary>")


@dataclass(frozen=True, slots=True)
class Seen:
    """What the probe compares from one request: the tools offered, and the
    tags in what is new since the speaker's last turn (tool results, notes)."""

    speaker: Speaker
    tools: list[str]
    witnesses: list[str]

    def as_json(self) -> Json:
        return {
            "speaker": self.speaker.value,
            "tools": list(self.tools),
            "witnesses": list(self.witnesses),
        }


def reply(request: dict[str, Json]) -> Turn | Unscripted:
    match speaker(request):
        case Speaker.CLASSIFIER:
            return ALLOW
        case Speaker.COMPACT:
            return SUMMARY
        case (Speaker.LEAD | Speaker.SUBAGENT) as who:
            step = sum(
                1 for message in messages(request) if message.get("role") == "assistant"
            )
            script = SCRIPTS[who]
            return script[step] if step < len(script) else Unscripted(who, step)


def seen(request: dict[str, Json]) -> Seen:
    tools = request.get("tools")
    names = (
        [str(tool.get("name")) for tool in tools if isinstance(tool, dict)]
        if isinstance(tools, list)
        else []
    )
    history = messages(request)
    turns = [
        index
        for index, message in enumerate(history)
        if message.get("role") == "assistant"
    ]
    new = text_of(
        [message.get("content") for message in history[turns[-1] + 1 if turns else 0 :]]
    )
    return Seen(speaker(request), names, [tag for tag in WITNESSES if tag in new])


def speaker(request: dict[str, Json]) -> Speaker:
    """Who asks, by what each request kind carries: the classifier stops on
    its verdict tag, the compactor asks for a `<summary>` block, and only the
    subagent's system prompt holds the marker."""
    match request:
        case {"stop_sequences": list(stops)} if "</severity>" in stops:
            return Speaker.CLASSIFIER
        case _ if "<summary>" in last_user_text(request):
            return Speaker.COMPACT
        case _ if SUBAGENT_MARKER in text_of(request.get("system")):
            return Speaker.SUBAGENT
        case _:
            return Speaker.LEAD


def last_user_text(request: dict[str, Json]) -> str:
    # Claude Code also sends `system` role messages, such as a hand-back notice.
    users = [message for message in messages(request) if message.get("role") == "user"]
    return text_of(users[-1].get("content")) if users else ""


def messages(request: dict[str, Json]) -> list[dict[str, Json]]:
    match request.get("messages"):
        case list() as found:
            return [message for message in found if isinstance(message, dict)]
        case _:
            return []


def text_of(content: Json) -> str:
    """Every string in a content tree, joined: text blocks, tool results, system."""
    match content:
        case str():
            return content
        case list():
            return "\n".join(text_of(item) for item in content)
        case dict():
            return "\n".join(
                text_of(value)
                for key, value in content.items()
                if key in {"text", "content", "input"} or isinstance(value, list)
            )
        case _:
            return ""


def response(turn: Turn, request: dict[str, Json], turn_id: str) -> tuple[str, bytes]:
    """The turn as the API sends it: an SSE stream when the request streams,
    else one JSON message (auto mode's classifier does not stream)."""
    match turn:
        case Text(text):
            block: dict[str, Json] = {"type": "text", "text": text}
            stop = "end_turn"
        case ToolUse(name, tool_input):
            block = {
                "type": "tool_use",
                "id": f"toolu_{turn_id}",
                "name": name,
                "input": tool_input,
            }
            stop = "tool_use"
    usage: Json = {"input_tokens": 1, "output_tokens": 1}
    message: dict[str, Json] = {
        "id": f"msg_{turn_id}",
        "type": "message",
        "role": "assistant",
        "model": request.get("model"),
        "content": [block],
        "stop_reason": stop,
        "stop_sequence": None,
        "usage": usage,
    }
    match request.get("stream"):
        case True:
            return "text/event-stream", stream(message, block)
        case _:
            return "application/json", json.dumps(message).encode()


def stream(message: dict[str, Json], block: dict[str, Json]) -> bytes:
    """https://docs.anthropic.com/en/api/messages-streaming: the block opens
    empty and its one delta carries the whole text or input."""
    match block:
        case {"type": "text", "text": text}:
            opened: Json = {**block, "text": ""}
            delta: Json = {"type": "text_delta", "text": text}
        case _:
            opened = {**block, "input": {}}
            delta = {
                "type": "input_json_delta",
                "partial_json": json.dumps(block.get("input")),
            }
    events: list[tuple[str, Json]] = [
        (
            "message_start",
            {
                "type": "message_start",
                "message": {**message, "content": [], "stop_reason": None},
            },
        ),
        (
            "content_block_start",
            {"type": "content_block_start", "index": 0, "content_block": opened},
        ),
        (
            "content_block_delta",
            {"type": "content_block_delta", "index": 0, "delta": delta},
        ),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {
                    "stop_reason": message.get("stop_reason"),
                    "stop_sequence": None,
                },
                "usage": message.get("usage"),
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]
    return b"".join(
        f"event: {name}\ndata: {json.dumps(data)}\n\n".encode() for name, data in events
    )


def serve(log: Path) -> ThreadingHTTPServer:
    """Listens on a free port of 127.0.0.1 in a daemon thread, appending what
    each request offered to `log`. The caller shuts it down."""
    counter = iter(range(1_000_000))
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version: str = "HTTP/1.1"

        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("content-length", "0")))
            request = cast("dict[str, Json]", json.loads(body))
            with lock:
                with log.open("a") as out:
                    _ = out.write(json.dumps(seen(request).as_json()) + "\n")
                turn_id = str(next(counter))
            match reply(request) if self.path.startswith("/v1/messages") else None:
                case Text() | ToolUse() as turn:
                    self.send(200, *response(turn, request, turn_id))
                case Unscripted(who, step):
                    self.fail(
                        f"the probe's mock has no turn {step} for the {who.value}"
                    )
                case None:
                    self.fail(f"the probe's mock does not serve {self.path}")

        def fail(self, message: str) -> None:
            error = {
                "type": "error",
                "error": {"type": "invalid_request_error", "message": message},
            }
            self.send(400, "application/json", json.dumps(error).encode())

        def send(self, status: int, content_type: str, body: bytes) -> None:
            self.send_response(status)
            self.send_header("content-type", content_type)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            _ = self.wfile.write(body)

        @override
        def log_message(self, format: str, *args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
