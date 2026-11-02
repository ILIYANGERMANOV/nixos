"""`just mutation-diff [base]` and `just mutation`: mutation testing, cut to a diff.

`diff BASE` lists the mutants on the new-side lines this checkout adds or edits
since its merge-base with BASE; `full` lists every mutant. mutmut runs the
changed Python modules by name, Stryker the TypeScript files whole and
incrementally, and each report is then cut to the changed lines.

stdout is the markdown report and, on its last line, the JSON's path. Tool
output goes to a log file. Exit 0 whatever survives: advisory. Non-zero only
when a run fails. The JSON is schema 1 of the mutation diff contract.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from collections.abc import Iterable, Mapping, Sequence
from contextlib import chdir
from dataclasses import dataclass
from importlib.metadata import version
from itertools import dropwhile
from pathlib import Path
from typing import ClassVar, Literal, assert_never, cast

import libcst as cst
from libcst.metadata import MetadataWrapper, PositionProvider
from mutmut.mutation.diff_apply import get_diff_for_mutant
from mutmut.stats import status_by_exit_code
from mutmut.utils.format_utils import orig_function_and_class_names_from_key

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

OUT_DIR = Path(".mutation")
PYTHON_SCRATCH = OUT_DIR / "python"
LOG = OUT_DIR / "mutation.log"

# Import name -> path. Only these import into their tests: the guards and the
# statusline run as subprocesses, where no mutant could ever be killed.
PYTHON_MODULES = {
    "analyze": "programs/agents/skills/custom/self-improve/scripts/analyze.py",
    "bash_commands": "programs/claude-code/bash_commands.py",
    "cache_check": "just/nix-darwin/cache_check.py",
    "disk_plan": "programs/software-factory/disk_plan.py",
    "hook_event": "programs/claude-code/hook_event.py",
    "transcripts": "programs/claude-code/transcripts.py",
}
# What those tests import or read from beside themselves.
PYTHON_TEST_SUPPORT = (
    "programs/claude-code/bash_corpus.py",
    "programs/claude-code/guard_harness.py",
    "just/nix-darwin/expensive-builds.deny",
)
TS_ROOT = Path("programs/playwright")
# The rest of TS_ROOT is Playwright drivers, which only checks.qa runs.
TS_FILES = ("kit/index.ts", "wallet/index.ts")

NOT_ASSESSED = (
    "Not assessed: this diff adds or edits no line of the mutated logic, the "
    f"{len(PYTHON_MODULES)} Python modules and the /qa wallet and kit. Deleted lines, "
    "tests, shell and Nix are not mutated, so this says nothing about the tests."
)

type Status = Literal["killed", "survived", "uncovered", "timedOut", "skipped"]
type Listed = Literal["survived", "uncovered", "timedOut"]
LISTED: tuple[Listed, ...] = ("survived", "uncovered", "timedOut")
STATUSES: tuple[Status, ...] = ("killed", *LISTED, "skipped")


@dataclass(frozen=True, slots=True)
class LineRange:
    """Inclusive, 1-based new-side lines."""

    first: int
    last: int


WHOLE_FILE = LineRange(1, sys.maxsize)

type ChangedLines = Mapping[str, tuple[LineRange, ...]]


@dataclass(frozen=True, slots=True)
class Mutant:
    """One mutant of a repository file, over the lines `span` it replaces."""

    file: str
    span: LineRange
    status: Status
    operator: str
    original: str
    replacement: str


@dataclass(frozen=True, slots=True)
class Diff:
    """The lines changed since `base`: the user's ref, the merge-base once resolved."""

    base: str


@dataclass(frozen=True, slots=True)
class Full:
    pass


type Mode = Diff | Full


@dataclass(frozen=True, slots=True)
class Assessed:
    totals: Mapping[Status, int]
    listed: tuple[Mutant, ...]


@dataclass(frozen=True, slots=True)
class NotAssessed:
    """No changed line lies in a mutated file, so no mutant was selected."""

    sentence: ClassVar[str] = NOT_ASSESSED


type Outcome = Assessed | NotAssessed


@dataclass(frozen=True, slots=True)
class Report:
    tool: str
    head: str
    mode: Mode
    outcome: Outcome


class RunFailedError(Exception):
    """A tool failed, or gave no result where one was due."""


def main(argv: Sequence[str]) -> int:
    requested = parse_mode(argv)
    shfmt = os.environ["SHFMT"]
    os.chdir(git("rev-parse", "--show-toplevel"))
    head = git("rev-parse", "HEAD")
    mode: Mode
    match requested:
        case Diff(ref):
            base = git("merge-base", ref, "HEAD")
            mode = Diff(base)
            changed = checkout_changes(base)
        case Full():
            mode = requested
            changed = dict.fromkeys(scope(), (WHOLE_FILE,))
        case _:
            assert_never(requested)

    OUT_DIR.mkdir(exist_ok=True)
    _ = LOG.write_text("")
    try:
        mutants = run_tools(changed, shfmt)
    except RunFailedError as failure:
        print(tail(LOG.read_text(), 30), file=sys.stderr)
        print(f"Mutation testing failed: {failure}. See {LOG}", file=sys.stderr)
        return 1

    report = mutation_diff(mutants, changed, tool=tool(), head=head, mode=mode)
    markdown = render_markdown(report)
    json_path = OUT_DIR / "mutation-diff.json"
    _ = json_path.write_text(json.dumps(report_json(report), indent=2) + "\n")
    _ = (OUT_DIR / "mutation-diff.md").write_text(markdown)
    print(markdown)
    print(json_path)
    return 0


def parse_mode(argv: Sequence[str]) -> Mode:
    match argv:
        case ["diff", ref]:
            return Diff(ref)
        case ["full"]:
            return Full()
        case _:
            raise SystemExit("usage: mutation diff BASE | mutation full")


def checkout_changes(base: str) -> ChangedLines:
    """The lines the working tree adds or edits since `base`, untracked files whole."""
    diff = git(
        "-c",
        "core.quotePath=false",
        "diff",
        "-U0",
        "--no-color",
        "--no-ext-diff",
        "--find-renames",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        base,
    )
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
    return changed_lines(diff) | {path: (WHOLE_FILE,) for path in untracked if path}


HUNK_HEADER = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def changed_lines(diff: str) -> dict[str, tuple[LineRange, ...]]:
    """The new-side lines `git diff -U0` output adds or edits, by file."""
    changed: dict[str, tuple[LineRange, ...]] = {}
    file: str | None = None
    body_left = 0
    # Not splitlines: a source line may hold a separator it would also cut at.
    for line in diff.split("\n"):
        if body_left > 0:
            # A body line, or git's "\ No newline at end of file" note, which is not.
            if not line.startswith("\\"):
                body_left -= 1
            continue
        if line.startswith("+++ "):
            file = new_side_path(line.removeprefix("+++ "))
            continue
        match HUNK_HEADER.match(line), file:
            case re.Match() as hunk, str(path):
                old_count, new_start, new_count = hunk.groups()
                added = line_count(new_count)
                body_left = line_count(old_count) + added
                if added > 0:
                    first = int(new_start)
                    changed[path] = (
                        *changed.get(path, ()),
                        LineRange(first, first + added - 1),
                    )
            case _:
                pass
    return changed


def line_count(group: str | None) -> int:
    return 1 if group is None else int(group)


# A path git had to quote keeps its quotes, so it matches no mutated file: no
# such name occurs among them.
def new_side_path(header: str) -> str | None:
    path = header.removesuffix("\t")
    return None if path == "/dev/null" else path.removeprefix("b/")


def scope() -> list[str]:
    return [*PYTHON_MODULES.values(), *(str(TS_ROOT / file) for file in TS_FILES)]


def run_tools(changed: ChangedLines, shfmt: str) -> list[Mutant]:
    """Every mutant of the files the changes reach, from each tool that mutates them."""
    modules = [name for name, path in PYTHON_MODULES.items() if path in changed]
    typescript = any(str(TS_ROOT / file) in changed for file in TS_FILES)
    mutants = [
        *(python_mutants(modules, shfmt) if modules else []),
        *(typescript_mutants() if typescript else []),
    ]
    mutated = {mutant.file for mutant in mutants}
    if empty := [path for path in scope() if path in changed and path not in mutated]:
        raise RunFailedError(f"no mutants at all in {', '.join(empty)}")
    return mutants


def mutation_diff(
    mutants: Iterable[Mutant],
    changed: ChangedLines,
    *,
    tool: str,
    head: str,
    mode: Mode,
) -> Report:
    return Report(tool=tool, head=head, mode=mode, outcome=outcome(mutants, changed))


def outcome(mutants: Iterable[Mutant], changed: ChangedLines) -> Outcome:
    """The mutants whose span overlaps a changed line, counted and listed."""
    if not any(path in changed for path in scope()):
        return NotAssessed()
    selected = [
        mutant
        for mutant in mutants
        if any(overlaps(mutant.span, lines) for lines in changed.get(mutant.file, ()))
    ]
    return Assessed(
        totals={
            status: sum(m.status == status for m in selected) for status in STATUSES
        },
        listed=tuple(
            sorted(
                (m for m in selected if m.status in LISTED),
                key=lambda m: (m.file, m.span.first),
            )
        ),
    )


def overlaps(a: LineRange, b: LineRange) -> bool:
    return a.first <= b.last and b.first <= a.last


def report_json(report: Report) -> Json:
    """`mutation-diff.json`, schema 1 of the mutation diff contract."""
    match report.outcome:
        case Assessed(totals, listed):
            not_assessed = ""
        case NotAssessed():
            totals, listed = dict.fromkeys(STATUSES, 0), ()
            not_assessed = NotAssessed.sentence
        case _:
            assert_never(report.outcome)
    return {
        "schema": 1,
        "tool": report.tool,
        "head": report.head,
        "base": json_base(report.mode),
        "totals": {"mutants": sum(totals.values()), **totals},
        "mutants": [
            {
                "file": m.file,
                "line": m.span.first,
                "status": m.status,
                "operator": m.operator,
                "original": m.original,
                "replacement": m.replacement,
            }
            for m in listed
        ],
        "notAssessed": not_assessed,
    }


def json_base(mode: Mode) -> str:
    match mode:
        case Diff(base):
            return base
        case Full():
            return ""
        case _:
            assert_never(mode)


def render_markdown(report: Report) -> str:
    """The compact report. Every repository-derived string sits in one diff fence,
    each of its lines starting with `@@`, `-` or `+`, so none can close the fence.
    """
    match report.mode:
        case Diff(base):
            scope_line = f"the lines changed since `{base[:7]}`"
        case Full():
            scope_line = "every mutated line"
        case _:
            assert_never(report.mode)
    intro = f"**Mutation diff** (advisory): {scope_line}, at `{report.head[:7]}`.\n"
    match report.outcome:
        case Assessed(totals, listed):
            return f"{intro}\n{assessed_markdown(totals, listed)}"
        case NotAssessed():
            return f"{intro}\n{NotAssessed.sentence}\n"
        case _:
            assert_never(report.outcome)


def assessed_markdown(t: Mapping[Status, int], listed: tuple[Mutant, ...]) -> str:
    table = (
        "| Mutants | Killed | Survived | Uncovered | Timed out | Skipped |\n"
        "| --- | --- | --- | --- | --- | --- |\n"
        f"| {sum(t.values())} | {t['killed']} | {t['survived']} | {t['uncovered']} "
        f"| {t['timedOut']} | {t['skipped']} |\n"
    )
    if not listed:
        return table
    blocks = "".join(mutant_block(m) for m in listed)
    return f"{table}\n```diff\n{blocks}```\n"


def mutant_block(mutant: Mutant) -> str:
    header = f"@@ {mutant.status} {one_line(mutant.file)}:{mutant.span.first} {one_line(mutant.operator)} @@"
    lines = [header, *fenced("-", mutant.original), *fenced("+", mutant.replacement)]
    return "".join(f"{line}\n" for line in lines)


def fenced(sign: str, code: str) -> list[str]:
    return [f"{sign} {one_line(line)}" for line in code.split("\n")]


# Control and line-separator characters, which could end a fenced line.
UNSAFE = re.compile("[\x00-\x1f\x7f\x85\u2028\u2029]")


def one_line(text: str) -> str:
    return UNSAFE.sub(" ", text)


def tool() -> str:
    package = cast(
        "dict[str, dict[str, str]]", json.loads((TS_ROOT / "package.json").read_text())
    )
    stryker = package["devDependencies"]["@stryker-mutator/core"]
    return f"mutmut {version('mutmut')} + StrykerJS {stryker}"


# ---- Python: mutmut ----


def python_mutants(modules: Sequence[str], shfmt: str) -> list[Mutant]:
    build_scratch(PYTHON_SCRATCH, shfmt)
    run(
        [sys.executable, "-m", "mutmut", "run", *(f"{m}.*" for m in modules)],
        PYTHON_SCRATCH,
    )
    return [
        mutant for module in modules for mutant in read_mutmut(PYTHON_SCRATCH, module)
    ]


# Hypothesis' deadline would time the trampoline mutmut wraps every function in,
# and its database would replay one mutant's failing example into the next.
CONFTEST = """\
from hypothesis import settings

settings.register_profile("mutation", deadline=None, database=None)
"""


def build_scratch(scratch: Path, shfmt: str) -> None:
    """A flat copy of the modules and their tests, as mutmut wants them.

    Rebuilt every run: mutmut keeps a kill when only a test changed, so a kept
    scratch could report a mutant killed by a test that no longer exists.
    """
    if scratch.exists():
        shutil.rmtree(scratch)
    (scratch / "src").mkdir(parents=True)
    tests = scratch / "tests"
    tests.mkdir()
    for path in map(Path, PYTHON_MODULES.values()):
        source = path.read_text().replace("@shfmt@", shfmt)
        _ = (scratch / "src" / path.name).write_text(source)
        # Unmutated beside the tests as well, for those that run it as a program.
        _ = (tests / path.name).write_text(source)
        _ = shutil.copy(path.with_name(f"test_{path.name}"), tests)
    for path in PYTHON_TEST_SUPPORT:
        _ = shutil.copy(path, tests)
    _ = (tests / "conftest.py").write_text(CONFTEST)
    _ = (scratch / "pyproject.toml").write_text(
        scratch_pyproject(Path("pyproject.toml").read_text())
    )


def scratch_pyproject(repository_pyproject: str) -> str:
    """The repository's pytest options, under the mutation profile, for the flat copy."""
    pytest = cast(
        "dict[str, dict[str, dict[str, dict[str, str]]]]",
        tomllib.loads(repository_pyproject),
    )
    addopts = pytest["tool"]["pytest"]["ini_options"]["addopts"]
    return f"""\
[tool.pytest.ini_options]
addopts = {json.dumps(f"{addopts} --hypothesis-profile=mutation")}
pythonpath = ["src", "tests"]
testpaths = ["tests"]

[tool.mutmut]
source_paths = ["src"]
pytest_add_cli_args_test_selection = ["tests"]
"""


def read_mutmut(scratch: Path, module: str) -> list[Mutant]:
    """Each mutant of `module` from mutmut's results, located in its source."""
    path = PYTHON_MODULES[module]
    meta = cast(
        "dict[str, dict[str, int | None]]",
        json.loads((scratch / "mutants" / "src" / f"{module}.py.meta").read_text()),
    )
    starts = function_lines(Path(path).read_text())
    mutants: list[Mutant] = []
    with chdir(scratch):
        for name, exit_code in meta["exit_code_by_key"].items():
            function, cls = orig_function_and_class_names_from_key(name)
            span = mutmut_span(
                get_diff_for_mutant(name, path=f"src/{module}.py"),
                starts[cls, function],
            )
            status = mutmut_status(status_by_exit_code[exit_code])
            mutants.append(
                Mutant(path, span.lines, status, name, span.original, span.replacement)
            )
    return mutants


def function_lines(source: str) -> dict[tuple[str | None, str], int]:
    """Where line 1 of mutmut's diff sits, for each top-level function and method.

    mutmut prints a function as libcst holds it, stripped: from the first comment
    directly above it, else its first decorator, else its `def`.
    """
    wrapper = MetadataWrapper(cst.parse_module(source))
    positions = wrapper.resolve(PositionProvider)

    def first_line(function: cst.FunctionDef) -> int:
        comments = list(
            dropwhile(lambda line: line.comment is None, function.leading_lines)
        )
        first = function.decorators[0] if function.decorators else function
        return positions[first].start.line - len(comments)

    body = wrapper.module.body
    top: dict[tuple[str | None, str], int] = {
        (None, node.name.value): first_line(node)
        for node in body
        if isinstance(node, cst.FunctionDef)
    }
    methods = {
        (cls.name.value, node.name.value): first_line(node)
        for cls in body
        if isinstance(cls, cst.ClassDef)
        for node in cls.body.body
        if isinstance(node, cst.FunctionDef)
    }
    return top | methods


@dataclass(frozen=True, slots=True)
class MutmutSpan:
    lines: LineRange
    original: str
    replacement: str


def mutmut_span(diff: str, function_line: int) -> MutmutSpan:
    """Where in the source a mutant applies, from mutmut's diff of its function.

    The diff compares the function's code with the mutant's, so its line 1 is
    the function's first line, at `function_line` in the source.
    """
    lines = diff.split("\n")
    hunk = next(i for i, line in enumerate(lines) if line.startswith("@@"))
    match re.match(r"@@ -(\d+)", lines[hunk]):
        case re.Match() as header:
            hunk_line = int(header[1])
        case None:
            raise ValueError(f"no hunk header in {lines[hunk]!r}")
    body = lines[hunk + 1 :]
    context = next(i for i, line in enumerate(body) if line.startswith("-"))
    removed = [line[1:].strip() for line in body if line.startswith("-")]
    added = [line[1:].strip() for line in body if line.startswith("+")]
    first = function_line + hunk_line - 1 + context
    return MutmutSpan(
        LineRange(first, first + len(removed) - 1), "\n".join(removed), "\n".join(added)
    )


def mutmut_status(status: str) -> Status:
    """mutmut's word for a mutant's result, as the contract counts it."""
    match status:
        case "killed" | "segfault":
            return "killed"
        case "survived":
            return "survived"
        # Reached by no test that imports it: a program the tests only run.
        case "no tests":
            return "uncovered"
        case "timeout" | "suspicious":
            return "timedOut"
        case "skipped" | "caught by type check":
            return "skipped"
        case _:
            raise RunFailedError(f"mutmut left a mutant {status}")


# ---- TypeScript: Stryker ----


def typescript_mutants() -> list[Mutant]:
    report = TS_ROOT / "reports" / "mutation" / "mutation.json"
    # A stale report must never pass for this run's.
    report.unlink(missing_ok=True)
    run(["pnpm", "install", "--frozen-lockfile"], TS_ROOT)
    run(["pnpm", "exec", "stryker", "run", "--mutate", ",".join(TS_FILES)], TS_ROOT)
    return stryker_mutants(cast("Json", json.loads(report.read_text())))


def stryker_mutants(report: Json) -> list[Mutant]:
    """The mutants of Stryker's `mutation.json`, by repository path."""
    match report:
        case {"files": dict(files)}:
            return [
                mutant
                for path, file in files.items()
                for mutant in stryker_file(str(TS_ROOT / path), file)
            ]
        case _:
            raise RunFailedError("Stryker's report has no files")


def stryker_file(path: str, file: Json) -> list[Mutant]:
    match file:
        case {"source": str(source), "mutants": list(mutants)}:
            return [stryker_mutant(path, source, mutant) for mutant in mutants]
        case _:
            raise RunFailedError(f"Stryker's report of {path} has no source or mutants")


def stryker_mutant(path: str, source: str, mutant: Json) -> Mutant:
    match mutant:
        case {
            "mutatorName": str(operator),
            "replacement": str(replacement),
            "status": str(status),
            "location": {
                "start": {"line": int(start_line), "column": int(start_column)},
                "end": {"line": int(end_line), "column": int(end_column)},
            },
        }:
            lines = LineRange(start_line, end_line)
            original = span_text(source, lines, start_column, end_column)
            return Mutant(
                path, lines, stryker_status(status), operator, original, replacement
            )
        case _:
            raise RunFailedError(
                f"a mutant of {path} that Stryker's schema does not have"
            )


def span_text(source: str, lines: LineRange, start_column: int, end_column: int) -> str:
    """Stryker's columns are 1-based and its end column is exclusive."""
    text = source.split("\n")[lines.first - 1 : lines.last]
    text[-1] = text[-1][: end_column - 1]
    text[0] = text[0][start_column - 1 :]
    return "\n".join(text)


def stryker_status(status: str) -> Status:
    """Stryker leaves compile and runtime errors out of its score; so does this."""
    match status:
        case "Killed":
            return "killed"
        case "Survived":
            return "survived"
        case "NoCoverage":
            return "uncovered"
        case "Timeout":
            return "timedOut"
        case "CompileError" | "RuntimeError" | "Ignored":
            return "skipped"
        case _:
            raise RunFailedError(f"Stryker left a mutant {status}")


# ---- Effects ----


def run(argv: Sequence[str], cwd: Path) -> None:
    """Runs a tool with its output appended to the log."""
    with LOG.open("a") as log:
        _ = log.write(f"$ {' '.join(argv)}\n")
        log.flush()
        result = subprocess.run(
            argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=False
        )
    if result.returncode != 0:
        raise RunFailedError(f"`{' '.join(argv)}` exited {result.returncode}")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout.rstrip("\n")


def tail(text: str, lines: int) -> str:
    return "\n".join(text.rstrip("\n").split("\n")[-lines:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
