"""client.py against a stand-in `claude`: a tiny Python program that prints
what the real client would, so no model or network is needed."""

import json
import sys
from pathlib import Path

import pytest
from client import ClaudeFailedError, claude, claude_version, hook, read_jsonl
from model import Json, Payload


def fake_claude(stdout: str, code: int = 0, stderr: str = "") -> list[str]:
    script = (
        f"import sys; sys.stdout.write({stdout!r}); "
        f"sys.stderr.write({stderr!r}); sys.exit({code})"
    )
    return [sys.executable, "-c", script]


def run(argv: list[str], repo: Path) -> str:
    return claude(argv, repo, {}, timeout=30)


def test_a_successful_run_returns_its_session_id(tmp_path: Path) -> None:
    argv = fake_claude(json.dumps({"session_id": "abc-123", "is_error": False}))

    assert run(argv, tmp_path) == "abc-123"


def test_the_run_happens_in_the_repo(tmp_path: Path) -> None:
    script = (
        "import json, os; "
        "print(json.dumps({'session_id': os.getcwd(), 'is_error': False}))"
    )

    assert run([sys.executable, "-c", script], tmp_path) == str(tmp_path)


def test_an_error_result_fails_even_on_exit_zero(tmp_path: Path) -> None:
    argv = fake_claude(json.dumps({"session_id": "abc", "is_error": True}))

    with pytest.raises(ClaudeFailedError):
        _ = run(argv, tmp_path)


def test_a_nonzero_exit_fails_and_keeps_stderr(tmp_path: Path) -> None:
    argv = fake_claude(
        json.dumps({"session_id": "abc", "is_error": False}), code=3, stderr="boom"
    )

    with pytest.raises(ClaudeFailedError, match="exited 3") as failure:
        _ = run(argv, tmp_path)
    assert failure.value.stderr == "boom"


def test_no_output_fails(tmp_path: Path) -> None:
    with pytest.raises(ClaudeFailedError):
        _ = run(fake_claude("", code=1), tmp_path)


def test_version_is_the_first_word_claude_prints(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binary = tmp_path / "claude"
    _ = binary.write_text(
        f"#!{sys.executable}\nprint('2.1.314 (Claude Code)')\n", encoding="utf-8"
    )
    binary.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path))

    assert claude_version() == "2.1.314"


def test_read_jsonl_of_a_missing_file_is_empty(tmp_path: Path) -> None:
    assert read_jsonl(tmp_path / "absent.jsonl") == []


def test_read_jsonl_returns_each_line_in_order(tmp_path: Path) -> None:
    log = tmp_path / "log.jsonl"
    _ = log.write_text('{"n": 1}\n{"n": 2}\n', encoding="utf-8")

    assert read_jsonl(log) == [{"n": 1}, {"n": 2}]


def test_hook_logs_the_payload_with_its_directory_and_prints_the_answer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(tmp_path)
    log = tmp_path / "events.jsonl"

    def respond(payload: Payload) -> Json:
        return {"seen": payload["hook_event_name"]}

    code = hook(log, json.dumps({"hook_event_name": "PreToolUse"}), respond)

    assert code == 0
    assert json.loads(capsys.readouterr().out) == {"seen": "PreToolUse"}
    assert read_jsonl(log) == [{"pwd": str(tmp_path), "hook_event_name": "PreToolUse"}]


def test_hook_appends_to_an_existing_log(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(tmp_path)
    log = tmp_path / "events.jsonl"

    for name in ("SubagentStart", "SubagentStop"):
        _ = hook(log, json.dumps({"hook_event_name": name}), lambda _p: {})

    assert [e["hook_event_name"] for e in read_jsonl(log)] == [
        "SubagentStart",
        "SubagentStop",
    ]
