"""What both probes share about driving the real `claude`: its version, one
`claude -p` run, and the recording hook it calls."""

import json
import shlex
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import cast

from model import Json, Payload


class ClaudeFailedError(Exception):
    def __init__(self, argv: list[str], code: int, stdout: str, stderr: str) -> None:
        super().__init__(
            f"`{shlex.join(argv[:2])} ...` exited {code}:\n{stdout}\n{stderr}"
        )
        self.stderr: str = stderr


def claude_version() -> str:
    result = subprocess.run(
        ["claude", "--version"], capture_output=True, text=True, check=True
    )
    return result.stdout.split()[0]


def claude(argv: list[str], repo: Path, env: dict[str, str], timeout: int) -> str:
    """Runs one `claude -p` and returns its session id."""
    result = subprocess.run(
        argv,
        cwd=repo,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    output = cast("Json", json.loads(result.stdout or "null"))
    match result.returncode, output:
        case 0, {"session_id": str(session), "is_error": False}:
            return session
        case code, _:
            raise ClaudeFailedError(argv, code, result.stdout, result.stderr)


def read_jsonl(path: Path) -> list[Payload]:
    lines = path.read_text().splitlines() if path.exists() else []
    return [cast("Payload", json.loads(line)) for line in lines]


def hook(log: Path, stdin: str, respond: Callable[[Payload], Json]) -> int:
    """The recording hook: logs the payload with the directory the hook ran
    in, and prints what `respond` answers it."""
    payload = cast("Payload", json.loads(stdin))
    with log.open("a") as out:
        _ = out.write(json.dumps({"pwd": str(Path.cwd()), **payload}) + "\n")
    print(json.dumps(respond(payload)))
    return 0
