"""`state-hook <name>`: the hooks that keep a run's record without the model
remembering to.

    resume    sessionStart          context: `state show` and `state next`
    spawn     beforeTool delegate   context: `state next`, a warning when the
                                    flow role spawned is neither the one advised
                                    nor one beside it, and a diff reader's prompt
                                    gets `Diff: <folder>`
    handback  beforeTool handback   records a worker's hand-back and appends
                                    what was recorded, or why not, to it
    pr        afterTool shell       `gh pr create` -> drafted, `gh pr ready` on
                                    the drafted PR -> ready; run as a command,
                                    not text in an argument or heredoc
    asked     afterTool ask         records a question asked while in Ctx

Each reads one event of the neutral contract (agent_hook.py) on stdin and
prints its result, or nothing. A worktree with no run, or a Done one, prints
nothing. None denies: a refusal or an error becomes context ("fail open and
tell"). Only the lead steers the run: a subagent's spawn, shell or question is
not the lead's, except a hand-back, which only a subagent makes.
"""

import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, cast, final, override

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

from state.codec import PR_URL_SHAPE, Line, pick
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
    WORKERS,
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
    """`gh pr ready`, not `--undo`, with the PR it names: a number, a URL or a
    branch; None for the current branch's."""

    pr: str | None


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
            case "pr", AfterTool(
                agent=agent, cwd=cwd, input=tool_input, output=output
            ) if is_lead(agent):
                return pr(cwd, tool_input, output)
            case "asked", AfterTool(agent=agent, cwd=cwd) if is_lead(agent):
                return asked(cwd)
            case ("resume", SessionStart()) | ("pr" | "asked", AfterTool()):
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
        case Failure() as failure:
            return Note(told("resume", failure))
        case Loaded(state=state):
            return Note(f"{show(state)}\n{next_advice(state, cwd)}".rstrip())


def spawn(cwd: Path, tool_input: JsonObject) -> Allow:
    match run_in(cwd):
        case None:
            return Allow()
        case Failure() as failure:
            return Allow(told("spawn", failure))
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


def pr(cwd: Path, tool_input: JsonObject, output: Json) -> Note:
    match pr_call(tool_input, output):
        case None:
            return Note()
        case found, stdout:
            pass
    match run_in(cwd):
        case None:
            return Note()
        case Failure() as failure:
            return Note(told("pr", failure))
        case Loaded() as run:
            pass
    match pr_event(found, stdout, run.state, cwd):
        case None:
            return Note()
        case Failure() as failure:
            return Note(told("pr", failure))
        case event:
            return Note(note(record(run, (event,), cwd)))


def asked(cwd: Path) -> Note:
    """Only while in Ctx: a question asked later is no step's count."""
    match run_in(cwd):
        case Loaded(state=State(step="Ctx")) as run:
            return Note(note(record(run, (Asked(1),), cwd)))
        case Failure() as failure:
            return Note(told("asked", failure))
        case _:
            return Note()


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
    """The `gh pr create` or `gh pr ready` a shell command runs, as any command
    of a chain such as `git push && gh pr create ...`. Text that only mentions
    one, as an argument or in a heredoc body, runs nothing."""
    for words in commands(command):
        match words:
            case ["gh", "pr", "create", *args]:
                return Create(flag_value(args, ("--base", "-B")))
            case ["gh", "pr", "ready", *args] if "--undo" not in args:
                return MarkReady(positional(args, ("--repo", "-R")))
            case _:
                pass
    return None


# The shell's operator characters: a run of them ends a command (`&&`, `|`, `;`,
# a newline, a subshell's `(`) or redirects (`>`, `<<`).
SHELL_PUNCTUATION = "();<>|&\n"
ENV_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.DOTALL)


def commands(command: str) -> list[list[str]]:
    """Each simple command's words, from its command word on: the env
    assignments before it dropped. A command that does not split, such as one
    with an unclosed quote, the shell would not run either."""
    # The shell drops a backslash-newline before it splits words.
    lexer = QuotingLexer(drop_heredocs(command.replace("\\\n", "")))
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        tokens = [(token, lexer.quoted) for token in lexer]
    except ValueError:
        return []
    found: list[list[str]] = [[]]
    for token, quoted in tokens:
        if not quoted and is_separator(token):
            found.append([])
        elif found[-1] or not ENV_ASSIGNMENT.fullmatch(token):
            found[-1].append(token)
    return found


@final
class QuotingLexer(shlex.shlex):
    """A POSIX shell lexer that also tells whether its last token was quoted or
    escaped, so `'&&'`, `\\&` and `''` stay words, never operators."""

    def __init__(self, command: str) -> None:
        self.quoted = False
        self._state: str | None = None
        super().__init__(command, posix=True, punctuation_chars=SHELL_PUNCTUATION)

    @override
    def read_token(self) -> str | None:
        self.quoted = False
        return super().read_token()

    # shlex keeps no quoted flag, but it enters a state named by each quote or
    # escape character it meets: watching its `state` writes recovers the flag.
    @property
    def state(self) -> str | None:
        return self._state

    @state.setter
    def state(self, value: str | None) -> None:
        self.quoted = self.quoted or (value is not None and value in "'\"\\")
        self._state = value


# `<<EOF`, `<<-'EOF'`; not a `<<<` here-string, which has no body.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z0-9_]+)\1")


def drop_heredocs(command: str) -> str:
    """The command without its heredoc bodies: text a command reads, not runs."""
    kept: list[str] = []
    open_bodies: list[str] = []
    for line in command.split("\n"):
        if not open_bodies:
            kept.append(line)
            open_bodies = [m.group(2) for m in HEREDOC.finditer(line)]
        elif line.strip() == open_bodies[0]:
            open_bodies = open_bodies[1:]
    return "\n".join(kept)


def is_separator(token: str) -> bool:
    """A run of punctuation that ends a command; a redirection does not."""
    return all(c in SHELL_PUNCTUATION for c in token) and not any(
        c in "<>" for c in token
    )


def flag_value(words: list[str], flags: tuple[str, ...]) -> str | None:
    for i, word in enumerate(words):
        if word in flags and i + 1 < len(words):
            return words[i + 1]
        for flag in flags:
            if word.startswith(f"{flag}="):
                return word.removeprefix(f"{flag}=")
    return None


def positional(words: list[str], valued: tuple[str, ...]) -> str | None:
    """The first argument that is no flag, nor the value of a flag in `valued`."""
    skip = False
    for word in words:
        match skip, word.startswith("-"):
            case True, _:
                skip = False
            case False, True:
                skip = word in valued
            case False, False:
                return word
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
        case MarkReady(pr=pr), Drafted(url=url):
            return Ready(url) if pr is None or names(pr, url) else None
        case MarkReady(), None:
            return Failure(
                "state: gh pr ready, but this run recorded no draft PR",
                "state record drafted <pr-url> <base>, then state record ready <pr-url>",
                2,
            )


def names(pr: str, url: str) -> bool:
    """`gh pr ready <pr>` names the PR at `url`: its number or its URL. A branch
    name is taken as another PR: telling it apart needs `gh`."""
    return pr in (url, url.rsplit("/", 1)[-1])


def default_branch(cwd: Path) -> str:
    """What `gh pr create` targets with no --base: origin's default branch."""
    ref = git(cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip()
    return ref.removeprefix("origin/")


# ---- The shell -------------------------------------------------------------------


def run_in(cwd: Path) -> Loaded | Failure | None:
    """The worktree's run; None outside a git work tree, with no run, or once
    the run is Done: a finished run has nothing left to record or advise."""
    match locate(cwd):
        case Failure():
            return None
        case git_dir if (git_dir / POINTER).exists():
            match load(git_dir):
                case Failure() as failure:
                    return failure
                case _, _, State(step="Done"):
                    return None
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


def told(hook: HookName, failure: Failure) -> str:
    return f"state hook {hook}: {note(failure)}"


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin.read()))
