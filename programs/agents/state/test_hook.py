"""The state hooks against temp git repos, with a run and without one."""

import io
import shutil
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

from state.hook import HookName, main, run_hook
from state.model import ROLES
from state.state_fixtures import (
    PR,
    GitHub,
    commit,
    git,
    log_of,
    ok,
    older_log,
    to_draft,
    to_implement,
    types,
)

SESSION = SessionId("s")
LEAD = None


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
    "asked": ask,
}

SUBAGENT_EVENTS: dict[HookName, Callable[[Path, Agent], Event]] = {
    "resume": start,
    "spawn": lambda cwd, by: delegate(cwd, "implementer", by),
    "handback": lambda cwd, by: BeforeTool(
        SESSION, cwd, by, Tool.HANDBACK, {"message": "READY done"}
    ),
    "asked": ask,
}

# What each hook says when it has nothing to say.
NOTHING: dict[HookName, Result] = {
    "resume": Note(),
    "spawn": Allow(),
    "handback": Allow(),
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


# A log an older `state` wrote does not parse: its run is not this one's.
@pytest.mark.parametrize("hook", EVENTS)
def test_a_log_that_does_not_parse_gets_nothing(
    repo: Path, notes: Path, hook: HookName
) -> None:
    broken_log(repo, notes)

    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]


# A run's notes dir removed by hand leaves its pointer behind.
@pytest.mark.parametrize("hook", EVENTS)
def test_a_pointer_to_a_deleted_log_gets_nothing_and_writes_nothing(
    tmp_path: Path, repo: Path, notes: Path, hook: HookName
) -> None:
    in_ctx(repo, notes)
    shutil.rmtree(notes)
    before = files(tmp_path)

    said = run_hook(hook, EVENTS[hook](repo))

    assert (said, files(tmp_path)) == (NOTHING[hook], before)


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
    to_implement(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")
    _ = ok(repo, "record", "ready", PR)

    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]


# ---- A run bound to its branch and PR --------------------------------------------


@pytest.mark.parametrize("hook", EVENTS)
def test_on_another_branch_every_hook_is_silent_and_reads_no_github(
    repo: Path, notes: Path, github: GitHub, hook: HookName
) -> None:
    to_implement(repo, notes)
    _ = git(repo, "switch", "--quiet", "--create", "other")

    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]
    assert github.calls() == []


def test_back_on_its_branch_the_hooks_speak_again(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    _ = git(repo, "switch", "--quiet", "--create", "other")
    _ = git(repo, "switch", "--quiet", "feature")

    assert context(run_hook("resume", start(repo))).startswith("Step: Implement\n")


@pytest.mark.parametrize("closed", ["MERGED", "CLOSED"])
@pytest.mark.parametrize("hook", EVENTS)
def test_once_its_pr_is_merged_or_closed_every_hook_is_silent(
    repo: Path, notes: Path, github: GitHub, hook: HookName, closed: str
) -> None:
    to_implement(repo, notes)
    github.open(draft=False, state=closed)

    assert run_hook(hook, EVENTS[hook](repo)) == NOTHING[hook]


@pytest.mark.parametrize("closed", ["MERGED", "CLOSED"])
def test_at_draft_plan_an_old_merged_or_closed_pr_on_the_branch_is_no_pr(
    repo: Path, notes: Path, github: GitHub, closed: str
) -> None:
    to_draft(repo, notes)
    github.open(draft=False, state=closed)
    before = types(notes)

    shown = context(run_hook("resume", start(repo)))

    assert (shown.startswith("Step: DraftPlan\n"), types(notes)) == (True, before)


def test_a_pr_opened_by_any_means_is_recorded_as_drafted(
    repo: Path, notes: Path
) -> None:
    to_draft(repo, notes)

    shown = context(run_hook("resume", start(repo)))

    assert shown.startswith("state: recorded 6 drafted -> Implement\nStep: Implement\n")
    assert log_of(notes)[-1]["event"] == {
        "type": "drafted",
        "url": PR,
        "base": "main",
        "branch": "feature",
    }


def test_a_pr_marked_ready_early_records_nothing_until_the_run_is_at_pr(
    repo: Path, notes: Path, github: GitHub
) -> None:
    to_implement(repo, notes)
    github.open(draft=False)
    before = types(notes)

    early = context(run_hook("spawn", delegate(repo, "implementer")))

    assert (early.startswith("SPAWN implementer\n"), types(notes)) == (True, before)


def test_at_pr_a_ready_pr_is_recorded_and_the_finished_run_is_silent(
    repo: Path, notes: Path, github: GitHub
) -> None:
    to_implement(repo, notes)
    _ = ok(repo, "override", "PR", "CI is green")
    github.open(draft=False)

    said = run_hook("resume", start(repo))

    assert (said, types(notes)[-1]) == (Note(), "ready")


def test_github_down_is_told_and_the_hook_works_from_the_log(
    repo: Path, notes: Path, github: GitHub
) -> None:
    to_implement(repo, notes)
    github.down("error connecting to api.github.com")

    spawned = context(run_hook("spawn", delegate(repo, "implementer")))

    assert spawned.splitlines()[:2] == [
        "state: PR sync skipped - gh pr view: error connecting to api.github.com",
        "SPAWN implementer",
    ]


def test_a_log_an_older_state_wrote_is_silent(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    older_log(notes)

    assert run_hook("resume", start(repo)) == Note()


# ---- resume ------------------------------------------------------------------------


def test_resume_shows_the_run_and_its_advice(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    shown = context(run_hook("resume", start(repo)))

    assert shown.startswith("Step: Implement\n")
    assert "\nSPAWN implementer\n" in shown


def test_resume_tells_a_subagent_nothing(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    assert run_hook("resume", start(repo, agent("implementer"))) == Note()


# ---- spawn -------------------------------------------------------------------------


def test_spawn_gives_the_advice_with_no_warning_for_the_advised_role(
    repo: Path, notes: Path
) -> None:
    to_implement(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "implementer"))

    assert spawned == Allow(context=context(spawned))
    assert context(spawned).startswith("SPAWN implementer\n")
    assert "state: the advice is" not in context(spawned)


def test_spawn_warns_when_another_role_is_spawned(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, "refactorer")))

    assert spawned.endswith("\nstate: the advice is SPAWN implementer, not refactorer")


@pytest.mark.parametrize("role", ["reviewer", "researcher", "checker"])
def test_spawn_gives_no_warning_for_a_role_spawned_beside_the_advice(
    repo: Path, notes: Path, role: str
) -> None:
    to_implement(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, role)))

    assert "state: the advice is" not in spawned


@pytest.mark.parametrize("role", ["Explore", "Plan", "fork", "claude-code-guide"])
def test_spawn_gives_the_advice_with_no_warning_for_a_role_outside_the_flow(
    repo: Path, notes: Path, role: str
) -> None:
    to_implement(repo, notes)

    spawned = context(run_hook("spawn", delegate(repo, role)))

    assert spawned.startswith("SPAWN implementer\n")
    assert "state: the advice is" not in spawned


def test_spawn_gives_no_warning_for_a_later_implementer_slice(
    repo: Path, notes: Path
) -> None:
    to_implement(repo, notes)
    _ = ok(repo, "record", "implemented")

    spawned = context(run_hook("spawn", delegate(repo, "implementer")))

    assert not spawned.startswith("SPAWN implementer\n")
    assert "state: the advice is" not in spawned


@pytest.mark.parametrize("role", sorted(ROLES))
def test_spawn_never_rewrites_the_prompt(repo: Path, notes: Path, role: str) -> None:
    to_implement(repo, notes)

    spawned = run_hook("spawn", delegate(repo, role))

    assert isinstance(spawned, Allow)
    assert spawned.updated_input is None
    assert context(spawned).startswith("SPAWN ")


def test_spawn_tells_a_git_failure(repo: Path, notes: Path) -> None:
    to_draft(repo, notes)
    _ = ok(repo, "record", "drafted", PR, "gone", "feature")

    spawned = context(run_hook("spawn", delegate(repo, "fixer")))

    assert spawned.startswith("state hook spawn: git diff")


def test_spawn_by_a_review_lead_is_not_the_runs(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "reviewer", agent("review-lead")))

    assert spawned == Allow()


def test_spawn_by_a_delegated_engineer_steers_the_run(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    spawned = run_hook("spawn", delegate(repo, "implementer", agent("engineer")))

    assert context(spawned).startswith("SPAWN implementer\n")


# ---- handback ----------------------------------------------------------------------


def test_handback_records_a_worker_and_appends_it_to_the_report(
    repo: Path, notes: Path
) -> None:
    to_implement(repo, notes)
    _ = commit(repo, {"b.txt": "two\n"}, "implement")

    report = updated(
        run_hook("handback", hand_back(repo, "implementer", "READY done")), "message"
    )

    assert report == "READY done\n\nstate: recorded 7 implemented -> Refactor"
    assert types(notes)[-1] == "implemented"


def test_handback_appends_a_refusal_and_its_fix_and_records_it_refused(
    repo: Path, notes: Path
) -> None:
    to_implement(repo, notes)
    before = types(notes)

    report = updated(
        run_hook("handback", hand_back(repo, "implementer", "done")), "message"
    )

    assert report.startswith("done\n\nstate handback implementer: line 1 starts 'done'")
    assert "\nfix: record it by hand: state record implemented" in report
    assert types(notes) == [*before, "refused"]


def test_a_hook_after_a_refused_handback_starts_with_the_warning(
    repo: Path, notes: Path
) -> None:
    to_implement(repo, notes)
    _ = run_hook("handback", hand_back(repo, "implementer", "done"))

    spawned = context(run_hook("spawn", delegate(repo, "implementer")))

    assert spawned.splitlines()[0].startswith(
        "state: WARN refused, not recorded: state handback implementer: line 1"
    )
    assert spawned.splitlines()[1].startswith("state: fix: record it by hand")


def test_handback_records_a_researcher_while_in_ctx(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    report = updated(
        run_hook("handback", hand_back(repo, "researcher", "notes")), "message"
    )

    assert report == "notes\n\nstate: recorded 2 researched -> Ctx"


def test_handback_skips_a_subagent_with_no_role(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    before = types(notes)
    no_role = BeforeTool(
        SESSION, repo, Agent(AgentId("a1"), None), Tool.HANDBACK, {"message": "done"}
    )

    assert run_hook("handback", no_role) == Allow()
    assert types(notes) == before


def test_handback_skips_a_subagent_with_no_id(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    before = types(notes)
    no_id = BeforeTool(
        SESSION, repo, Agent(None, None), Tool.HANDBACK, {"message": "done"}
    )

    assert run_hook("handback", no_id) == Allow()
    assert types(notes) == before


def test_handback_skips_a_researcher_past_ctx(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    before = types(notes)

    assert run_hook("handback", hand_back(repo, "researcher", "notes")) == Allow()
    assert types(notes) == before


def test_handback_skips_a_reviewer(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)

    assert run_hook("handback", hand_back(repo, "reviewer", "READY")) == Allow()


# ---- asked -------------------------------------------------------------------------


def test_asked_records_a_question_in_ctx(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    assert context(run_hook("asked", ask(repo))) == "state: recorded 2 asked -> Ctx"


def test_asked_skips_a_question_past_ctx(repo: Path, notes: Path) -> None:
    to_implement(repo, notes)
    before = types(notes)

    assert run_hook("asked", ask(repo)) == Note()
    assert types(notes) == before


def test_asked_by_a_subagent_is_not_the_runs(repo: Path, notes: Path) -> None:
    in_ctx(repo, notes)

    assert run_hook("asked", ask(repo, agent("researcher"))) == Note()
