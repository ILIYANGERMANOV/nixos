"""`state-hook <name>`: the hooks that keep a run's record without the model
remembering to.

    resume    sessionStart          context: `state show` and `state next`
    spawn     beforeTool delegate   context: `state next`, a warning when the
                                    role spawned is neither the one advised nor
                                    one beside it, and a diff reader's prompt
                                    gets `Diff: <folder>`
    handback  beforeTool handback   records a worker's hand-back and appends
                                    what was recorded, or why not, to it
    pr        afterTool shell       `gh pr create` -> drafted, `gh pr ready` -> ready
    asked     afterTool ask         records a question asked while in Ctx

Each reads one event of the neutral contract (agent_hook.py) on stdin and
prints its result, or nothing. A worktree with no run prints nothing. None
denies: a refusal or an error becomes context ("fail open and tell"). Only the
lead steers the run: a subagent's spawn, shell or question is not the lead's,
except a hand-back, which only a subagent makes.
"""

import shlex
import subprocess
import sys
from dataclasses import dataclass
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
    Result,
    SessionStart,
    emit_result,
    parse_event,
)

from state.codec import PR_URL_SHAPE, Line
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
    append,
    facts_of,
    git,
    head_of,
    load,
    locate,
    next_advice,
)
from state.model import (
    ROLES,
    Asked,
    Drafted,
    Failure,
    Ready,
    Researched,
    State,
    StateName,
    values_of,
)
from state.model import (
    Event as StateEvent,
)

type HookName = Literal["resume", "spawn", "handback", "pr", "asked"]
HOOKS = cast("tuple[HookName, ...]", values_of(HookName))

# The roles that read the branch diff, once a draft PR names its base.
DIFF_READERS = frozenset({"refactorer", "review-lead", "fixer"})

# Spawned beside the advised role, never instead of it: a dry-run reviewer next
# to the review-lead, a fact-gap researcher, a checker for the full check.
BESIDE_ADVICE = frozenset({"reviewer", "researcher", "checker"})


@dataclass(frozen=True, slots=True)
class Loaded:
    """A worktree's run: its log, the lines read and the state they fold to."""

    log: Path
    lines: list[Line]
    state: State


@dataclass(frozen=True, slots=True)
class Create:
    """`gh pr create`, with its `--base` when given."""

    base: str | None


@dataclass(frozen=True, slots=True)
class MarkReady:
    """`gh pr ready`, not `--undo`."""


type PrCommand = Create | MarkReady


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
        case Allow(context=None, updated_input=None):
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
    try:
        return dispatch(hook, event)
    except (GitError, OSError) as error:
        return Allow(context=f"state hook {hook}: {error}")


def dispatch(hook: HookName, event: Event) -> Result:
    match hook, event:
        case "resume", SessionStart(agent=agent, cwd=cwd) if is_lead(agent):
            return resume(cwd)
        case "spawn", BeforeTool(agent=agent, cwd=cwd, input=tool_input) if is_lead(
            agent
        ):
            return spawn(cwd, tool_input)
        case "handback", BeforeTool(agent=Agent(role=role), cwd=cwd, input=tool_input):
            return handback(role, cwd, tool_input)
        case "pr", AfterTool(agent=agent, cwd=cwd, input=tool_input, output=output) if (
            is_lead(agent)
        ):
            return pr(cwd, tool_input, output)
        case "asked", AfterTool(agent=agent, cwd=cwd) if is_lead(agent):
            return asked(cwd)
        case (
            ("resume", SessionStart())
            | ("spawn" | "handback", BeforeTool())
            | (
                "pr" | "asked",
                AfterTool(),
            )
        ):
            return Allow()
        case _:
            raise ValueError(
                f"state-hook {hook} does not run at {type(event).__name__}"
            )


def is_lead(agent: Agent | None) -> bool:
    """The lead is no subagent, or one whose role the run does not know, such
    as a delegated engineer. A review-lead spawning reviewers is a worker."""
    return agent is None or agent.role not in ROLES


# ---- The hooks -------------------------------------------------------------------


def resume(cwd: Path) -> Result:
    match run_in(cwd):
        case None:
            return Allow()
        case Failure() as failure:
            return told("resume", failure)
        case Loaded(state=state):
            return Allow(context=f"{show(state)}\n{next_advice(state, cwd)}".rstrip())


def spawn(cwd: Path, tool_input: JsonObject) -> Result:
    match run_in(cwd):
        case None:
            return Allow()
        case Failure() as failure:
            return told("spawn", failure)
        case Loaded(state=state):
            pass
    advice = advise(state, facts_of(state, cwd))
    role = tool_input.get("subagent_type")
    warning = (
        [f"state: the advice is SPAWN {advice.role}, not {role}"]
        if isinstance(advice, Spawn) and off_advice(advice.role, role, state.step)
        else []
    )
    context = "\n".join([render_advice(advice).rstrip("\n"), *warning])
    match state.drafted, tool_input.get("prompt"):
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


def off_advice(advised: str, spawned: Json, step: StateName) -> bool:
    """A spawn worth a warning: not the advised role, nor one spawned beside it.
    Implementer slices run one after another, so a later slice spawns while the
    advice has moved on to the refactorer."""
    match spawned:
        case str(role) if role == advised or role in BESIDE_ADVICE:
            return False
        case "implementer" if step in ("Impl", "Impl'"):
            return False
        case _:
            return True


def handback(role: str, cwd: Path, tool_input: JsonObject) -> Result:
    match tool_input.get("message"):
        case str(message):
            pass
        case _:
            return Allow()
    match run_in(cwd):
        case None:
            return Allow()
        case Failure() as failure:
            recorded: str | Failure = failure
        case Loaded() as run:
            match handed_back(role, message, run, cwd):
                case None:
                    return Allow()
                case result:
                    recorded = result
    return Allow(
        updated_input=tool_input | {"message": f"{message}\n\n{note(recorded)}"}
    )


def handed_back(
    role: str, message: str, run: Loaded, cwd: Path
) -> str | Failure | None:
    """What a role's hand-back records; None for a role whose report the run
    does not follow (a reviewer's goes to its review-lead)."""
    match role:
        case "implementer" | "refactorer" | "fixer" | "review-lead":
            match parse_handback(role, message, HandbackOptions(), head_of(cwd)):
                case Failure() as failure:
                    return failure
                case events:
                    return record(run, events, cwd)
        case "researcher" if run.state.step == "Ctx":
            return record(run, (Researched(1),), cwd)
        case _:
            return None


def pr(cwd: Path, tool_input: JsonObject, output: Json) -> Result:
    match pr_call(tool_input, output):
        case None:
            return Allow()
        case found, stdout:
            pass
    match run_in(cwd):
        case None:
            return Allow()
        case Failure() as failure:
            return told("pr", failure)
        case Loaded() as run:
            pass
    match pr_event(found, stdout, run.state, cwd):
        case None:
            return Allow()
        case Failure() as failure:
            return told("pr", failure)
        case event:
            return Allow(context=note(record(run, (event,), cwd)))


def asked(cwd: Path) -> Result:
    """Only while in Ctx: a question asked later is no step's count."""
    match run_in(cwd):
        case Loaded(state=State(step="Ctx")) as run:
            return Allow(context=note(record(run, (Asked(1),), cwd)))
        case Failure() as failure:
            return told("asked", failure)
        case _:
            return Allow()


# ---- `gh pr` -----------------------------------------------------------------------


def pr_call(tool_input: JsonObject, output: Json) -> tuple[PrCommand, str] | None:
    """A shell call that ran `gh pr create` or `gh pr ready`, and its stdout."""
    match tool_input.get("command"), output:
        case str(command), {"stdout": str(stdout)}:
            found = pr_command(command)
            return None if found is None else (found, stdout)
        case _:
            return None


def pr_command(command: str) -> PrCommand | None:
    """The `gh pr create` or `gh pr ready` in a shell command, anywhere in a
    chain such as `git push && gh pr create ...`."""
    words = split(command)
    for i in range(len(words) - 2):
        match words[i : i + 3]:
            case ["gh", "pr", "create"]:
                return Create(flag_value(words[i + 3 :], ("--base", "-B")))
            case ["gh", "pr", "ready"] if "--undo" not in words[i + 3 :]:
                return MarkReady()
            case _:
                pass
    return None


def split(command: str) -> list[str]:
    """Shell words. A heredoc body with a lone quote is no valid shell word
    list, but its `gh pr` words are plain, so whitespace finds them."""
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def flag_value(words: list[str], flags: tuple[str, ...]) -> str | None:
    for i, word in enumerate(words):
        if word in flags and i + 1 < len(words):
            return words[i + 1]
        for flag in flags:
            if word.startswith(f"{flag}="):
                return word.removeprefix(f"{flag}=")
    return None


def pr_event(
    found: PrCommand, stdout: str, state: State, cwd: Path
) -> StateEvent | Failure | None:
    """None when the command made no PR: gh printed no URL."""
    match found, state.drafted:
        case Create(base=base), _:
            urls = [match.group() for match in PR_URL_SHAPE.finditer(stdout)]
            if not urls:
                return None
            return Drafted(urls[-1], base or default_branch(cwd))
        case MarkReady(), Drafted(url=url):
            return Ready(url)
        case MarkReady(), None:
            return Failure(
                "state: gh pr ready, but this run recorded no draft PR",
                "state record drafted <pr-url> <base>, then state record ready <pr-url>",
                2,
            )


def default_branch(cwd: Path) -> str:
    """What `gh pr create` targets with no --base: origin's default branch."""
    ref = git(cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip()
    return ref.removeprefix("origin/")


# ---- The shell -------------------------------------------------------------------


def run_in(cwd: Path) -> Loaded | Failure | None:
    """The worktree's run; None outside a git work tree or with no run."""
    match locate(cwd):
        case Failure():
            return None
        case git_dir if (git_dir / POINTER).exists():
            match load(git_dir):
                case Failure() as failure:
                    return failure
                case log, lines, state:
                    return Loaded(log, lines, state)
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


def told(hook: HookName, failure: Failure) -> Result:
    return Allow(context=f"state hook {hook}: {note(failure)}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin.read()))
