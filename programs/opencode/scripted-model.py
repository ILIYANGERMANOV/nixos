"""A scripted stand-in for an OpenAI-compatible chat completions API, so
check-headless.sh runs opencode-kategory-headless offline and the same way
every run.

It answers `POST .../chat/completions` with one streamed turn
(https://platform.openai.com/docs/api-reference/chat-streaming), picked by
the request: a title request gets a title, the run's first turn one shell
call running <command>, the turn after its result <final-text>. A
request it has no turn for gets a 400 naming it, which OpenCode reports and
exits 1 on, where a 500 would be retried.

Usage: scripted-model.py <port-file> <command> <final-text>. It listens on a free loopback port and
writes the port to <port-file> once it accepts connections.
"""

import json
import sys
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast, override

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
type Payload = dict[str, Json]


@dataclass(frozen=True, slots=True)
class Text:
    text: str


@dataclass(frozen=True, slots=True)
class ShellCall:
    command: str


@dataclass(frozen=True, slots=True)
class Script:
    command: str
    final_text: str


@dataclass(frozen=True, slots=True)
class Unscripted:
    why: str


type Turn = Text | ShellCall | Unscripted


def turn(script: Script, request: Payload) -> Turn:
    """The reply to one request. OpenCode asks for a session title with no
    tools and a system prompt about titles; the run itself sends its tools."""
    messages = [m for m in as_list(request.get("messages")) if isinstance(m, dict)]
    tool_results = sum(1 for m in messages if m.get("role") == "tool")
    system = " ".join(
        str(m.get("content")) for m in messages if m.get("role") == "system"
    )
    match (bool(request.get("tools")), tool_results):
        case (False, _) if "title" in system.lower():
            return Text("Headless check")
        case (True, 0):
            return ShellCall(script.command)
        case (True, 1):
            return Text(script.final_text)
        case (tools, results):
            return Unscripted(f"no turn for tools={tools} tool_results={results}")


def as_list(value: Json) -> list[Json]:
    return value if isinstance(value, list) else []


def stream(reply: Text | ShellCall) -> bytes:
    """The turn as server-sent events, ending with OpenAI's [DONE]."""
    delta: Payload
    match reply:
        case Text(text):
            delta = {"role": "assistant", "content": text}
            finish = "stop"
        case ShellCall(command):
            arguments = json.dumps(
                {"command": command, "description": "the scripted command"}
            )
            call: Payload = {
                "index": 0,
                "id": "call_1",
                "type": "function",
                "function": {"name": "bash", "arguments": arguments},
            }
            delta = {"role": "assistant", "content": None, "tool_calls": [call]}
            finish = "tool_calls"
    events = [chunk(delta, None), chunk({}, finish), "[DONE]"]
    return "".join(f"data: {event}\n\n" for event in events).encode()


def chunk(delta: Payload, finish: str | None) -> str:
    return json.dumps(
        {
            "id": "scripted",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "scripted",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
    )


def handler(script: Script) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            request = cast(
                "Payload",
                json.loads(self.rfile.read(int(self.headers["Content-Length"]))),
            )
            match turn(script, request):
                case Unscripted(why):
                    error = {"error": {"message": why, "type": "invalid_request_error"}}
                    self.send(400, "application/json", json.dumps(error).encode())
                case Text() | ShellCall() as reply:
                    self.send(200, "text/event-stream", stream(reply))

        def send(self, status: int, content_type: str, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            _ = self.wfile.write(body)

        @override
        def log_message(self, format: str, *args: object) -> None:
            pass

    return Handler


def main() -> None:
    script = Script(command=sys.argv[2], final_text=sys.argv[3])
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(script))
    # Written whole, then renamed, so a reader never sees half a port.
    port_file = Path(sys.argv[1])
    partial = port_file.with_suffix(".partial")
    _ = partial.write_text(str(server.server_address[1]))
    _ = partial.replace(port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
