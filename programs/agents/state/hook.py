"""`state-hook <name>`: the hooks that keep a run's record without the model
remembering to.

    resume    sessionStart          context: `state show` and `state next`
    spawn     beforeTool delegate   context: `state next`, a warning when the
                                    flow role spawned is neither the one advised
                                    nor one beside it, and a diff reader's prompt
                                    with no `Diff:` line gets `Diff: <folder>`
    handback  beforeTool handback   records a worker's hand-back and appends
                                    what was recorded, or why not, to it
    asked     afterTool ask         records a question asked while in Ctx

Each reads one event of the neutral contract (agent_hook.py) on stdin and
prints its result, or nothing. Each syncs the run from GitHub first, as
`state next` does, and adds what that recorded. A worktree with no run prints
nothing, nor does a run that is Done, bound to another branch than HEAD's, whose
PR is merged or closed, or whose log does not parse. None denies: a refusal or
an error becomes context ("fail open and tell"). Only the lead steers the run: a subagent's spawn, shell or question is
not the lead's, except a hand-back, which only a subagent makes.
"""

import subprocess
import sys
from pathlib import Path
from typing import Literal, cast

from agent_hook import (
    AfterTool,
    Agent,
    Allow,
    BeforeTool,
    Event,
    Json,
    JsonObject,
    Note,
    Observed,
    Result,
    SessionStart,
    emit_result,
    parse_event,
)

from state.codec import pick
from state.core import (
    HandbackOptions,
    Spawn,
    advise,
    parse_handback,
    render_advice,
    show,
)
from state.effects import (
    POINTER,
    GitError,
    Loaded,
    Quiet,
    append,
    facts_of,
    head_of,
    locate,
    next_advice,
    open_run,
)
from state.model import (
    ROLES,
    WORKERS,
    Asked,
    Drafted,
    Failure,
    Researched,
    State,
    StateName,
    values_of,
)
from state.model import (
    Event as StateEvent,
)

type HookName = Literal["resume", "spawn", "handback", "asked"]
HOOKS = cast("tuple[HookName, ...]", values_of(HookName))

# The roles that read the branch diff, once a draft PR names its base.
DIFF_READERS = frozenset({"refactorer", "review-lead", "fixer"})

# Spawned beside the advised role, never instead of it: a dry-run reviewer next
# to the review-lead, a fact-gap researcher, a checker for the full check.
BESIDE_ADVICE = frozenset({"reviewer", "researcher", "checker"})


def main(argv: list[str], stdin: str) -> int:
    match hook_named(argv):
        case None:
            _ = sys.stderr.write(f"usage: state-hook {' | '.join(HOOKS)}\n")
            return 2
        case hook:
            pass
    try:
        event = parse_event(stdin)
    except ValueError as error:
        _ = sys.stderr.write(f"state-hook {hook}: {error}\n")
        return 2
    match run_hook(hook, event):
        case Allow(context=None, updated_input=None) | Note(context=None):
            pass
        case result:
            _ = sys.stdout.write(emit_result(result))
    return 0


def hook_named(argv: list[str]) -> HookName | None:
    match argv:
        case [name]:
            return next((hook for hook in HOOKS if hook == name), None)
        case _:
            return None


def run_hook(hook: HookName, event: Event) -> Result:
    match event:
        case BeforeTool():
            return before_tool(hook, event)
        case SessionStart() | AfterTool():
            return observed(hook, event)


def before_tool(hook: HookName, event: BeforeTool) -> Allow:
    try:
        match hook, event:
            case "spawn", BeforeTool(agent=agent, cwd=cwd, input=tool_input) if is_lead(
                agent
            ):
                return spawn(cwd, tool_input)
            case "handback", BeforeTool(
                agent=Agent(role=role), cwd=cwd, input=tool_input
            ):
                return handback(role, cwd, tool_input)
            case "spawn" | "handback", _:
                return Allow()
            case _:
                raise not_at(hook, event)
    except (GitError, OSError) as error:
        return Allow(context=f"state hook {hook}: {error}")


def observed(hook: HookName, event: Observed) -> Note:
    try:
        match hook, event:
            case "resume", SessionStart(agent=agent, cwd=cwd) if is_lead(agent):
                return resume(cwd)
            case "asked", AfterTool(agent=agent, cwd=cwd) if is_lead(agent):
                return asked(cwd)
            case ("resume", SessionStart()) | ("asked", AfterTool()):
                return Note()
            case _:
                raise not_at(hook, event)
    except (GitError, OSError) as error:
        return Note(f"state hook {hook}: {error}")


def not_at(hook: HookName, event: Event) -> ValueError:
    return ValueError(f"state-hook {hook} does not run at {type(event).__name__}")


def is_lead(agent: Agent | None) -> bool:
    """The lead is no subagent, or one whose role the run does not know, such
    as a delegated engineer. A review-lead spawning reviewers is a worker."""
    return agent is None or agent.role not in ROLES


# ---- The hooks -------------------------------------------------------------------


def resume(cwd: Path) -> Note:
    match run_in(cwd):
        case None:
            return Note()
        case Loaded(state=state, told=synced):
            return Note(
                joined(note(synced), show(state), next_advice(state, cwd).rstrip())
            )


def spawn(cwd: Path, tool_input: JsonObject) -> Allow:
    match run_in(cwd):
        case None:
            return Allow()
        case Loaded(state=state, told=synced):
            pass
    advice = advise(state, facts_of(state, cwd))
    role = tool_input.get("subagent_type")
    warning = (
        [f"state: the advice is SPAWN {advice.role}, not {role}"]
        if isinstance(advice, Spawn) and off_advice(advice.role, role, state.step)
        else []
    )
    context = joined(note(synced), render_advice(advice).rstrip("\n"), *warning)
    # A prompt that already has its Diff: line passes unchanged: auto mode
    # rejects input a hook rewrote after its review and asks for a resend, so
    # rewriting the resend again would block the spawn forever.
    match state.drafted, tool_input.get("prompt"):
        case Drafted(), str(prompt) if has_diff_line(prompt):
            return Allow(context)
        case Drafted(base=base), str(prompt) if role in DIFF_READERS:
            match ctx_folder(cwd, base):
                case Failure() as failure:
                    return Allow(context=f"{context}\n{note(failure)}")
                case folder:
                    return Allow(
                        context, tool_input | {"prompt": f"{prompt}\nDiff: {folder}"}
                    )
        case _:
            return Allow(context)


def has_diff_line(prompt: str) -> bool:
    return any(line.startswith("Diff: ") for line in prompt.splitlines())


def off_advice(advised: str, spawned: Json, step: StateName) -> bool:
    """A spawn worth a warning: a flow role, not the advised one, nor one
    spawned beside it. Implementer slices run one after another, so a later
    slice spawns while the advice has moved on to the refactorer. A role outside
    the flow (Explore, Plan, a fork) is no step of the run."""
    match spawned:
        case "implementer" if step in ("Impl", "Impl'"):
            return False
        case str(role) if role in ROLES:
            return role != advised and role not in BESIDE_ADVICE
        case _:
            return False


def handback(role: str, cwd: Path, tool_input: JsonObject) -> Allow:
    match tool_input.get("message"):
        case str(message):
            pass
        case _:
            return Allow()
    match run_in(cwd):
        case None:
            return Allow()
        case Loaded() as run:
            pass
    match handed_back(role, message, run, cwd):
        case None:
            return Allow()
        case recorded:
            said = joined(note(run.told), note(recorded))
            return Allow(updated_input=tool_input | {"message": f"{message}\n\n{said}"})


def handed_back(
    role: str, message: str, run: Loaded, cwd: Path
) -> str | Failure | None:
    """What a role's hand-back records; None for a role whose report the run
    does not follow (a reviewer's goes to its review-lead)."""
    match pick(role, WORKERS):
        case None if role == "researcher" and run.state.step == "Ctx":
            return record(run, (Researched(1),), cwd)
        case None:
            return None
        case worker:
            match parse_handback(worker, message, HandbackOptions(), head_of(cwd)):
                case Failure() as failure:
                    return failure
                case events:
                    return record(run, events, cwd)


def asked(cwd: Path) -> Note:
    """Only while in Ctx: a question asked later is no step's count."""
    match run_in(cwd):
        case Loaded(state=State(step="Ctx")) as run:
            return Note(joined(note(run.told), note(record(run, (Asked(1),), cwd))))
        case Loaded(told=synced):
            return Note(note(synced) or None)
        case None:
            return Note()


# ---- The shell -------------------------------------------------------------------


def run_in(cwd: Path) -> Loaded | None:
    """The worktree's run, synced from GitHub; None outside a git work tree,
    with no run, or one the hooks stay silent on (`open_run`). A log that does
    not parse is silent too: a run an older `state` wrote, which `state show`
    explains."""
    match locate(cwd):
        case Failure():
            return None
        case git_dir if (git_dir / POINTER).exists():
            match open_run(git_dir, cwd):
                case Loaded() as run:
                    return run
                case Quiet() | Failure():
                    return None
        case _:
            return None


def record(run: Loaded, events: tuple[StateEvent, ...], cwd: Path) -> str | Failure:
    return append(run.log, run.lines, run.state, events, cwd)


def ctx_folder(cwd: Path, base: str) -> str | Failure:
    """The branch diff's folder: `ctx diff`'s line 1."""
    done = subprocess.run(
        ["ctx", "diff", f"origin/{base}"],
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if done.returncode != 0:
        return Failure(
            f"state: ctx diff origin/{base} failed - {done.stderr.strip()}",
            f"run ctx diff origin/{base} and give the worker its folder",
            done.returncode,
        )
    match done.stdout.splitlines():
        case [folder, *_]:
            return folder
        case _:
            return Failure(
                f"state: ctx diff origin/{base} printed no folder",
                f"run ctx diff origin/{base} and give the worker its folder",
                1,
            )


def note(recorded: str | Failure) -> str:
    """What was recorded, a line each, or the refusal and its fix."""
    match recorded:
        case Failure(message=message, fix=fix):
            return f"{message}\nfix: {fix}"
        case lines:
            return "".join(f"state: {line}\n" for line in lines.splitlines()).rstrip(
                "\n"
            )


def joined(*parts: str) -> str:
    """The non-empty parts, a line each."""
    return "\n".join(part for part in parts if part)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin.read()))
