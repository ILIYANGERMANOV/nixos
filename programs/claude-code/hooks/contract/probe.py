"""`just probe-agents-hooks`: the Claude Code hook contract our hooks rely on,
snapshotted from the real `claude` client and compared to snapshot.json.

`claude -p` runs in a throwaway repo against model.py, a scripted stand-in
for the Messages API on 127.0.0.1, with a dummy key and its own config dir:
no login, no network, no cost, and the same turns every run. A recording
hook sees every SessionStart, PreToolUse and PostToolUse, rewrites three
inputs, and the mock sees whether the rewrites reached the next turn.

    probe.py <snapshot.json> [--update]   run, compare, print the summary line
    probe.py hook <log.jsonl>             the recording hook `claude` runs
"""

import difflib
import json
import os
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from model import (
    HANDBACK_TAG,
    ORIGINAL_COMMAND,
    REWRITE_TAG,
    SPAWN_TAG,
    SUBAGENT_MARKER,
    SUBAGENT_TYPE,
    Json,
    serve,
)

# The speakers whose tools and witnesses are the contract; the classifier's
# and compactor's requests are the client's business.
CONVERSATIONS = ("lead", "subagent")
# Each `claude -p` call takes about a second against the mock.
TIMEOUT_SECONDS = 120


@dataclass(frozen=True, slots=True)
class Logs:
    """What one probe run left: the repo it ran in, every hook payload, and
    what the mock saw of every request."""

    repo: Path
    hooks: list[dict[str, Json]]
    requests: list[dict[str, Json]]


class ClaudeFailedError(Exception):
    pass


def main(argv: list[str]) -> int:
    match argv:
        case ["hook", log]:
            return hook(Path(log), sys.stdin.read())
        case [snapshot]:
            return check(Path(snapshot), update=False)
        case [snapshot, "--update"]:
            return check(Path(snapshot), update=True)
        case _:
            print(__doc__, file=sys.stderr)
            return 2


def check(snapshot: Path, *, update: bool) -> int:
    version = claude_version()
    with tempfile.TemporaryDirectory(prefix="probe-agents-hooks-") as work:
        try:
            observed = record(run(Path(work)))
        except ClaudeFailedError as error:
            print(error, file=sys.stderr)
            print(f"probe-agents-hooks: claude-code {version} FAIL")
            return 1
    if update:
        _ = snapshot.write_text(json.dumps(observed, indent=2) + "\n")
        print(f"probe-agents-hooks: wrote {snapshot}")
    differences = diff(cast("Json", json.loads(snapshot.read_text())), observed)
    print("".join(differences), end="", file=sys.stderr)
    print(
        f"probe-agents-hooks: claude-code {version} {'FAIL' if differences else 'PASS'}"
    )
    return 1 if differences else 0


def diff(expected: Json, observed: Json) -> list[str]:
    """Empty when they agree, else one unified diff of the two snapshots."""
    return list(
        difflib.unified_diff(
            json.dumps(expected, indent=2).splitlines(keepends=True),
            json.dumps(observed, indent=2).splitlines(keepends=True),
            "snapshot.json",
            "observed",
        )
    )


def claude_version() -> str:
    result = subprocess.run(
        ["claude", "--version"], capture_output=True, text=True, check=True
    )
    return result.stdout.split()[0]


def run(work: Path) -> Logs:
    repo, config, home = work / "repo", work / "config", work / "home"
    for directory in (repo / "sub", config, home):
        directory.mkdir(parents=True)
    hooks_log, requests_log = work / "hooks.jsonl", work / "requests.jsonl"
    settings = work / "settings.json"
    _ = settings.write_text(json.dumps(recording_settings(hooks_log)))
    server = serve(requests_log)
    try:
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(config),
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}",
            "ANTHROPIC_API_KEY": "probe-dummy-key",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        }
        # Auto mode, not a bypass: Claude Code offers SubagentHandback only
        # there, and its classifier, which the mock always lets pass, is asked
        # about the calls no rule below allows.
        base = ["claude", "-p", "--output-format", "json", "--permission-mode", "auto"]
        base += ["--setting-sources", "project", "--settings", str(settings)]
        session = claude(
            [
                *base,
                "--agents",
                json.dumps(PROBE_AGENT),
                "--allowedTools",
                "Bash(echo *)",
                "Bash(cd *)",
                "Bash(pwd)",
                "--",
                "probe",
            ],
            repo,
            env,
        )
        _ = claude([*base, "--resume", session, "/compact"], repo, env)
    finally:
        server.shutdown()
    return Logs(repo, read_jsonl(hooks_log), read_jsonl(requests_log))


PROBE_AGENT = {
    SUBAGENT_TYPE: {
        "description": "Runs the hook probe's subagent turns",
        "prompt": f"{SUBAGENT_MARKER}: run the turns you are given.",
        "tools": ["Bash", "SubagentHandback"],
    }
}


def recording_settings(log: Path) -> Json:
    command = shlex.join(
        [sys.executable, str(Path(__file__).resolve()), "hook", str(log)]
    )
    hooks: list[Json] = [{"type": "command", "command": command}]
    return {
        "hooks": {
            # The matchers our SessionStart hooks register (codegen/hooks.nix).
            "SessionStart": [{"matcher": "startup|resume|compact", "hooks": hooks}],
            "PreToolUse": [{"matcher": "*", "hooks": hooks}],
            "PostToolUse": [{"matcher": "*", "hooks": hooks}],
        }
    }


def claude(argv: list[str], repo: Path, env: dict[str, str]) -> str:
    """Runs one `claude -p` and returns its session id."""
    result = subprocess.run(
        argv,
        cwd=repo,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
        check=False,
    )
    output = cast("Json", json.loads(result.stdout or "null"))
    match result.returncode, output:
        case 0, {"session_id": str(session), "is_error": False}:
            return session
        case code, _:
            raise ClaudeFailedError(
                f"`{shlex.join(argv[:2])} ...` exited {code}:\n{result.stdout}\n{result.stderr}"
            )


def read_jsonl(path: Path) -> list[dict[str, Json]]:
    lines = path.read_text().splitlines() if path.exists() else []
    return [cast("dict[str, Json]", json.loads(line)) for line in lines]


def hook(log: Path, stdin: str) -> int:
    payload = cast("dict[str, Json]", json.loads(stdin))
    with log.open("a") as out:
        _ = out.write(json.dumps({"pwd": str(Path.cwd()), **payload}) + "\n")
    print(json.dumps(rewrite(payload)))
    return 0


def rewrite(payload: dict[str, Json]) -> Json:
    """The PreToolUse output that rewrites one of the three probed inputs."""
    match payload:
        case {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command, **rest},
        } if command == ORIGINAL_COMMAND:
            updated: Json = {**rest, "command": f"echo {REWRITE_TAG}"}
        case {
            "hook_event_name": "PreToolUse",
            "tool_name": "Agent",
            "tool_input": {"prompt": str(prompt), **rest},
        }:
            updated = {**rest, "prompt": f"{prompt} {SPAWN_TAG}"}
        case {
            "hook_event_name": "PreToolUse",
            "tool_name": "SubagentHandback",
            "tool_input": {"message": str(message), **rest},
        }:
            updated = {**rest, "message": f"{message} {HANDBACK_TAG}"}
        case _:
            return {}
    return {
        "hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": updated}
    }


def record(logs: Logs) -> Json:
    """The run with its ids, paths, timings and counts taken out: what two
    runs of one Claude Code share, and a newer one may break."""
    return {
        "offered": {
            speaker: offered(logs.requests, speaker) for speaker in CONVERSATIONS
        },
        "requests": [
            {"speaker": request.get("speaker"), "witnesses": request.get("witnesses")}
            for request in logs.requests
            if request.get("speaker") in CONVERSATIONS
        ],
        "events": [event(payload, logs.repo) for payload in logs.hooks],
    }


def offered(requests: list[dict[str, Json]], speaker: str) -> Json:
    return names(
        {
            str(name)
            for request in requests
            if request.get("speaker") == speaker
            for name in as_list(request.get("tools"))
        }
    )


def event(payload: dict[str, Json], repo: Path) -> Json:
    """One hook payload as its contract: which keys it has, where it ran, and
    the tool's input and output that our hooks read."""
    shown: dict[str, Json] = {
        "event": payload.get("hook_event_name"),
        "keys": names(key for key in payload if key != "pwd"),
        "cwd": relative(str(payload.get("cwd")), repo),
        "hook_runs_in_cwd": payload.get("pwd") == payload.get("cwd"),
        **{key: payload[key] for key in ("source", "agent_type") if key in payload},
    }
    match payload:
        case {"tool_name": name, "tool_input": tool_input}:
            shown["tool"] = name
            shown["input"] = tool_input
        case _:
            pass
    match payload:
        case {"tool_name": "Bash", "tool_response": {"stdout": str(stdout), **rest}}:
            shown["response_keys"] = names(["stdout", *rest])
            # Resolved first: macOS reports /tmp as /private/tmp.
            shown["stdout"] = stdout.replace(str(repo.resolve()), "<repo>").replace(
                str(repo), "<repo>"
            )
        case {"tool_response": dict() as response}:
            shown["response_keys"] = names(response)
        case _:
            pass
    return shown


def names(items: Iterable[str]) -> Json:
    """Sorted, so a client that reorders keys or tools changes nothing."""
    ordered: list[Json] = [*sorted(items)]
    return ordered


def relative(cwd: str, repo: Path) -> str:
    path = Path(cwd).resolve()
    return (
        str(path.relative_to(repo.resolve()))
        if path.is_relative_to(repo.resolve())
        else "<outside the repo>"
    )


def as_list(value: Json) -> list[Json]:
    return value if isinstance(value, list) else []


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
