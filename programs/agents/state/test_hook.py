"""The state hooks against temp git repos, with a run and without one. `ctx` is
a fake on PATH: the real one writes under /tmp/ctx, which the box shares."""

import io
import os
from collections.abc import Callable
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest
from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    Allow,
    BeforeTool,
    Event,
    JsonObject,
    Note,
    Result,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
)
from hypothesis import given
from hypothesis import strategies as st

from state.hook import Create as CreatePr
from state.hook import HookName, MarkReady, main, pr_command, run_hook
from state.state_fixtures import PR, commit, git, log_of, ok, to_draft, to_impl

SESSION = SessionId("s")
LEAD = None


@pytest.fixture(autouse=True)
def fake_ctx(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A `ctx` printing a folder named after its base, failing when CTX_FAILS
    and printing nothing when CTX_SILENT."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    script = bin_dir / "ctx"
    _ = script.write_text(
        """#!/bin/sh
[ -n "$CTX_FAILS" ] && { echo "ctx: bad ref" >&2; exit 2; }
[ -n "$CTX_SILENT" ] && exit 0
echo "/tmp/ctx/$1-${2#origin/}"
echo "refs: $2..HEAD"
"""
    )
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")


@pytest.fixture
def notes(tmp_path: Path) -> Path:
    return tmp_path / "notes"


# ---- Builders ----------------------------------------------------------------------


def agent(role: str) -> Agent:
    return Agent(AgentId("a1"), Role(role))


def start(cwd: Path, by: Agent | None = LEAD) -> SessionStart:
    return SessionStart(SESSION, cwd, by, Source.STARTUP)


def delegate(cwd: Path, role: str, by: Agent | None = LEAD) -> BeforeTool:
    tool_input: JsonObject = {"prompt": "Do it.", "subagent_type": role}
    return BeforeTool(SESSION, cwd, by, Tool.DELEGATE, tool_input)


def hand_back(cwd: Path, role: str, report: str) -> BeforeTool:
    return BeforeTool(SESSION, cwd, agent(role), Tool.HANDBACK, {"message": report})


def shell(cwd: Path, command: str, stdout: str, by: Agent | None = LEAD) -> AfterTool:
    output: JsonObject = {"stdout": stdout, "stderr": "", "interrupted": False}
    return AfterTool(SESSION, cwd, by, Tool.SHELL, {"command": command}, output)


def ask(cwd: Path, by: Agent | None = LEAD) -> AfterTool:
    return AfterTool(SESSION, cwd, by, Tool.ASK, {"questions": []}, {"answers": {}})


def context(result: Result) -> str:
    match result:
        case Allow(context=str(said)) | Note(context=str(said)):
            return said
        case _:
            raise AssertionError(f"no context: {result!r}")


def updated(result: Result, field: str) -> str:
    assert isinstance(result, Allow)
    assert result.updated_input is not None
    text = result.updated_input[field]
    assert isinstance(text, str)
    return text


def types(notes: Path) -> list[object]:
    return [
        event["type"]
        for line in log_of(notes)
        if isinstance(event := line["event"], dict)
    ]


def files(root: Path) -> set[Path]:
    return set(root.rglob("*"))


def in_ctx(repo: Path, notes: Path) -> None:
    _ = ok(repo, "init", "--notes", str(notes))


def broken_log(repo: Path, notes: Path) -> None:
    """A run whose log ends in a line that does not parse."""
    in_ctx(repo, notes)
    with (notes / "events.jsonl").open("a") as log:
        _ = log.write("not json\n")


EVENTS: dict[HookName, Callable[[Path], Event]] = {
    "resume": start,
    "spawn": lambda cwd: delegate(cwd, "implementer"),
    "handback": lambda cwd: hand_back(cwd, "implementer", "READY done"),
    "pr": lambda cwd: shell(cwd, "gh pr create --base main", PR),
    "asked": ask,
}

SUBAGENT_EVENTS: dict[HookName, Callable[[Path, Agent], Event]] = {
    "resume": start,
    "spawn": lambda cwd, by: delegate(cwd, "implementer", by),
    "handback": lambda cwd, by: hand_back(cwd, by.role, "READY done"),
    "pr": lambda cwd, by: shell(cwd, "gh pr create --base main", PR, by),
    "asked": ask,
}

# What each hook says when it has nothing to say.
NOTHING: dict[HookName, Result] = {
    "resume": Note(),
    "spawn": Allow(),
    "handback": Allow(),
    "pr": Note(),
    "asked": Note(),
}


# ---- Every hook ----------------------------------------------------------------------


@pytest.mark.parametrize("hook", EVENTS)
def test_a_worktree_with_no_run_gets_nothing(repo: Path, hook: HookName) -> None:
    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]


# A subagent's hook `cwd` is its spawner's start folder, never its own worktree.
@pytest.mark.parametrize("role", ["implementer", "engineer"])
@pytest.mark.parametrize("hook", SUBAGENT_EVENTS)
def test_a_subagent_in_a_worktree_with_no_run_gets_nothing_and_writes_nothing(
    tmp_path: Path, repo: Path, hook: HookName, role: str
) -> None:
    before = files(tmp_path)

    said = run_hook(hook, SUBAGENT_EVENTS[hook](repo, agent(role)))

    assert (said, files(tmp_path)) == (NOTHING[hook], before)


@pytest.mark.parametrize("hook", EVENTS)
def test_a_folder_outside_git_gets_nothing(tmp_path: Path, hook: HookName) -> None:
    assert run_hook(hook, EVENTS[hook](tmp_path)) == NOTHING[hook]


@pytest.mark.parametrize("hook", ["resume", "spawn", "pr", "asked"])
def test_a_log_that_does_not_parse_is_told_not_raised(
    repo: Path, notes: Path, hook: HookName
) -> None:
    broken_log(repo, notes)

    assert "fix:" in context(run_hook(hook, EVENTS[hook](repo)))


def test_a_log_that_does_not_parse_is_told_on_the_hand_back(
    repo: Path, notes: Path
) -> None:
    broken_log(repo, notes)

    told = run_hook("handback", EVENTS["handback"](repo))

    assert "fix:" in updated(told, "message")


def test_main_prints_nothing_for_no_run(repo: Path) -> None:
    stdin = (
        f'{{"event":"sessionStart","session":"s","cwd":"{repo}",'
        '"agent":null,"source":"startup"}'
    )
    out = io.StringIO()
    with redirect_stdout(out):
        code = main(["resume"], stdin)

    assert (code, out.getvalue()) == (0, "")


@pytest.mark.parametrize(
    ("argv", "stdin"), [(["teleport"], "{}"), (["resume"], "{}"), ([], "{}")]
)
def test_main_refuses_an_unknown_hook_or_event(argv: list[str], stdin: str) -> None:
    with redirect_stderr(io.StringIO()):
        assert main(argv, stdin) == 2


@pytest.mark.parametrize("hook", EVENTS)
def test_a_finished_run_gets_nothing(repo: Path, notes: Path, hook: HookName) -> None:
    to_impl(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")
    _ = ok(repo, "record", "ready", PR)

    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]


# ---- resume ------------------------------------------------------------------------


def test_resume_shows_the_run_and_its_advice(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    shown = context(run_hook("resume", start(repo)))

    assert shown.startswith("Step: Impl\n")
    assert "\nSPAWN implementer\n" in shown


def test_resume_tells_a_subagent_nothing(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    assert run_hook("resume", start(repo, agent("implementer"))) == Note()


# ---- spawn -------------------------------------------------------------------------


def test_spawn_gives_the_advice_with_no_warning_for_the_advised_role(
    repo: Path, notes: Path
) -> None:
    to_impl(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "implementer"))

    assert spawned == Allow(context=context(spawned))
    assert context(spawned).startswith("SPAWN implementer\n")
    assert "state: the advice is" not in context(spawned)


def test_spawn_warns_when_another_role_is_spawned(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, "refactorer")))

    assert spawned.endswith("\nstate: the advice is SPAWN implementer, not refactorer")


@pytest.mark.parametrize("role", ["reviewer", "researcher", "checker"])
def test_spawn_gives_no_warning_for_a_role_spawned_beside_the_advice(
    repo: Path, notes: Path, role: str
) -> None:
    to_impl(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, role)))

    assert "state: the advice is" not in spawned


@pytest.mark.parametrize("role", ["Explore", "Plan", "fork", "claude-code-guide"])
def test_spawn_gives_the_advice_with_no_warning_for_a_role_outside_the_flow(
    repo: Path, notes: Path, role: str
) -> None:
    to_impl(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, role)))

    assert spawned.startswith("SPAWN implementer\n")
    assert "state: the advice is" not in spawned


def test_spawn_gives_no_warning_for_a_later_implementer_slice(
    repo: Path, notes: Path
) -> None:
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented")

    spawned = context(run_hook("spawn", delegate(repo, "implementer")))

    assert not spawned.startswith("SPAWN implementer\n")
    assert "state: the advice is" not in spawned


@pytest.mark.parametrize("role", ["refactorer", "review-lead", "fixer"])
def test_spawn_hands_a_diff_reader_the_branch_diff_folder(
    repo: Path, notes: Path, role: str
) -> None:
    to_impl(repo, notes)

    prompt = updated(run_hook("spawn", delegate(repo, role)), "prompt")

    assert prompt == "Do it.\nDiff: /tmp/ctx/diff-main"


def test_spawn_gives_no_folder_before_a_draft_names_the_base(
    repo: Path, notes: Path
) -> None:
    in_ctx(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "refactorer"))

    assert isinstance(spawned, Allow)
    assert spawned.updated_input is None


def test_spawn_tells_when_ctx_fails_and_leaves_the_prompt(
    repo: Path, notes: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    to_impl(repo, notes)
    monkeypatch.setenv("CTX_FAILS", "1")

    spawned = run_hook("spawn", delegate(repo, "fixer"))

    assert isinstance(spawned, Allow)
    assert spawned.updated_input is None
    assert "\nstate: ctx diff origin/main failed - ctx: bad ref\nfix:" in context(
        spawned
    )


def test_spawn_tells_when_ctx_prints_no_folder(
    repo: Path, notes: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    to_impl(repo, notes)
    monkeypatch.setenv("CTX_SILENT", "1")

    spawned = run_hook("spawn", delegate(repo, "fixer"))

    assert isinstance(spawned, Allow)
    assert spawned.updated_input is None
    assert "\nstate: ctx diff origin/main printed no folder\nfix:" in context(spawned)


def test_spawn_tells_a_git_failure(repo: Path, notes: Path) -> None:
    to_draft(repo, notes)
    _ = ok(repo, "record", "drafted", PR, "gone")

    spawned = context(run_hook("spawn", delegate(repo, "fixer")))

    assert spawned.startswith("state hook spawn: git diff")


def test_spawn_by_a_review_lead_is_not_the_runs(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "reviewer", agent("review-lead")))

    assert spawned == Allow()


def test_spawn_by_a_delegated_engineer_steers_the_run(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "implementer", agent("engineer")))

    assert context(spawned).startswith("SPAWN implementer\n")


# ---- handback ----------------------------------------------------------------------


def test_handback_records_a_worker_and_appends_it_to_the_report(
    repo: Path, notes: Path
) -> None:
    to_impl(repo, notes)
    _ = commit(repo, {"b.txt": "two\n"}, "implement")

    report = updated(
        run_hook("handback", hand_back(repo, "implementer", "READY done")), "message"
    )

    assert report == "READY done\n\nstate: recorded 7 implemented -> Impl'"
    assert types(notes)[-1] == "implemented"


def test_handback_appends_a_refusal_and_its_fix_and_records_nothing(
    repo: Path, notes: Path
) -> None:
    to_impl(repo, notes)
    before = types(notes)

    report = updated(
        run_hook("handback", hand_back(repo, "implementer", "done")), "message"
    )

    assert report.startswith("done\n\nstate handback implementer: line 1 starts 'done'")
    assert "\nfix: record it by hand: state record implemented" in report
    assert types(notes) == before


def test_handback_records_a_researcher_while_in_ctx(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    report = updated(
        run_hook("handback", hand_back(repo, "researcher", "notes")), "message"
    )

    assert report == "notes\n\nstate: recorded 2 researched -> Ctx"


def test_handback_skips_a_researcher_past_ctx(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)
    before = types(notes)

    assert run_hook("handback", hand_back(repo, "researcher", "notes")) == Allow()
    assert types(notes) == before


def test_handback_skips_a_reviewer(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)

    assert run_hook("handback", hand_back(repo, "reviewer", "READY")) == Allow()


# ---- pr ----------------------------------------------------------------------------


def test_pr_records_the_draft_gh_printed_with_its_base(repo: Path, notes: Path) -> None:
    to_draft(repo, notes)
    command = 'git push -u origin HEAD && gh pr create --draft --base main --title "x"'

    told = context(run_hook("pr", shell(repo, command, f"Creating\n{PR}\n")))

    assert told == "state: recorded 6 drafted -> Impl"
    assert log_of(notes)[-1]["event"] == {"type": "drafted", "url": PR, "base": "main"}


def test_pr_takes_origins_default_branch_without_a_base(
    repo: Path, notes: Path
) -> None:
    to_draft(repo, notes)
    _ = git(
        repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"
    )

    _ = run_hook("pr", shell(repo, "gh pr create --fill", f"{PR}\n"))

    assert log_of(notes)[-1]["event"] == {"type": "drafted", "url": PR, "base": "main"}


def test_pr_records_nothing_when_gh_printed_no_url(repo: Path, notes: Path) -> None:
    to_draft(repo, notes)
    before = types(notes)

    assert run_hook("pr", shell(repo, "gh pr create --base main", "")) == Note()
    assert types(notes) == before


@pytest.mark.parametrize(
    "command", ["gh pr ready", "gh pr ready 7", f"gh pr ready {PR}"]
)
def test_pr_records_ready_with_the_drafted_url(
    repo: Path, notes: Path, command: str
) -> None:
    to_impl(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")

    told = context(run_hook("pr", shell(repo, command, "")))

    assert told == "state: recorded 8 ready -> Done"
    assert log_of(notes)[-1]["event"] == {"type": "ready", "url": PR}


@pytest.mark.parametrize(
    "command",
    [
        "gh pr ready 12",
        "gh pr ready https://github.com/o/r/pull/12",
        "gh pr ready -R o/r 12",
    ],
)
def test_pr_ignores_ready_on_another_pr(repo: Path, notes: Path, command: str) -> None:
    to_impl(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")
    before = types(notes)

    assert run_hook("pr", shell(repo, command, "")) == Note()
    assert types(notes) == before


def test_pr_tells_ready_with_no_draft_recorded(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    told = context(run_hook("pr", shell(repo, "gh pr ready", "")))

    assert "no draft PR" in told
    assert "\nfix: state record drafted" in told


@pytest.mark.parametrize(
    "command",
    [
        "gh pr ready --undo",
        "gh pr view",
        "echo 'gh pr create'",
        "ls",
        "echo gh pr ready",
        "echo run gh pr create --base main && ls",
        "gh pr edit 7 --body-file - <<EOF\nrun gh pr ready 7\nEOF",
        "gh pr edit 7 --body-file - <<'EOF'\ngh pr create --base main\nEOF\nls",
        "gh pr ready --undo && gh pr view",
    ],
)
def test_pr_ignores_other_commands(repo: Path, notes: Path, command: str) -> None:
    to_draft(repo, notes)
    before = types(notes)

    assert run_hook("pr", shell(repo, command, PR)) == Note()
    assert types(notes) == before


def test_pr_by_a_subagent_is_not_the_runs(repo: Path, notes: Path) -> None:
    to_draft(repo, notes)

    assert (
        run_hook("pr", shell(repo, "gh pr create -B main", PR, agent("fixer")))
        == Note()
    )


WORD = st.text(alphabet="abcxyz-_/.", min_size=1, max_size=8)
SEPARATOR = st.sampled_from([" && ", " || ", "; ", " | ", "\n", " ("])
ENV = st.lists(st.sampled_from(["GH_TOKEN=x ", "A_1=b/c "]), max_size=2)


@given(
    prefix=st.lists(st.lists(WORD, min_size=1, max_size=3), max_size=3),
    separator=SEPARATOR,
    env=ENV,
    base=WORD,
)
def test_pr_finds_gh_pr_create_as_any_command_in_a_chain(
    prefix: list[list[str]], separator: str, env: list[str], base: str
) -> None:
    command = separator.join(
        [
            *(" ".join(words) for words in prefix),
            f"{''.join(env)}gh pr create -B {base}",
        ]
    )

    assert pr_command(command) == CreatePr(base)


def test_pr_finds_gh_pr_ready_past_a_heredoc_shlex_cannot_split() -> None:
    assert pr_command("cat <<'EOF'\nit's\nEOF\ngh pr ready") == MarkReady(None)


# ---- asked -------------------------------------------------------------------------


def test_asked_records_a_question_in_ctx(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    assert context(run_hook("asked", ask(repo))) == "state: recorded 2 asked -> Ctx"


def test_asked_skips_a_question_past_ctx(repo: Path, notes: Path) -> None:
    to_impl(repo, notes)
    before = types(notes)

    assert run_hook("asked", ask(repo)) == Note()
    assert types(notes) == before


def test_asked_by_a_subagent_is_not_the_runs(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    assert run_hook("asked", ask(repo, agent("researcher"))) == Note()
