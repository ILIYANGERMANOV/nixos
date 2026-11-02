"""The pure half of the mutation runner: diff parsing, mutant location, the report."""

import difflib

import pytest
from hypothesis import given
from hypothesis import strategies as st
from mutation_diff import (
    NOT_ASSESSED,
    Assessed,
    Diff,
    Full,
    Json,
    LineRange,
    Mutant,
    Report,
    RunFailedError,
    Status,
    changed_functions,
    changed_lines,
    function_lines,
    mutation_diff,
    mutmut_span,
    mutmut_status,
    one_line,
    render_markdown,
    report_json,
    stryker_mutants,
    stryker_status,
)

DISK_PLAN = "programs/software-factory/disk_plan.py"
KIT = "programs/playwright/kit/index.ts"

# Real `git diff -U0` output, as checkout_changes asks git for it.
GIT_DIFF = """\
diff --git a/gone.py b/gone.py
index 04ec35a..206b378 100644
--- a/gone.py
+++ b/gone.py
@@ -2 +1,0 @@ x
-y
diff --git a/m.py b/m.py
index 0fdf397..007f726 100644
--- a/m.py
+++ b/m.py
@@ -2 +2 @@ a
-b
+B
@@ -6,0 +7,2 @@ f
+g
+h
diff --git a/new.py b/new.py
new file mode 100644
index 0000000..80ce8d9
--- /dev/null
+++ b/new.py
@@ -0,0 +1,2 @@
+new1
+new2
diff --git a/nonl.py b/nonl.py
index c54071e..adde431 100644
--- a/nonl.py
+++ b/nonl.py
@@ -2 +2 @@ keep
-last
\\ No newline at end of file
+last
"""


def test_changed_lines_are_the_new_side_of_every_hunk() -> None:
    assert changed_lines(GIT_DIFF) == {
        "m.py": (LineRange(2, 2), LineRange(7, 8)),
        "new.py": (LineRange(1, 2),),
        "nonl.py": (LineRange(2, 2),),
    }


def test_a_deleted_file_changes_no_line() -> None:
    diff = "--- a/gone.py\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-x\n-y\n"

    assert changed_lines(diff) == {}


def test_an_added_line_that_reads_like_a_file_header_stays_a_body_line() -> None:
    diff = "--- a/m.py\n+++ b/m.py\n@@ -0,0 +1,2 @@\n+++ b/other.py\n+@@ -1 +1 @@\n"

    assert changed_lines(diff) == {"m.py": (LineRange(1, 2),)}


def test_a_no_newline_note_is_not_a_body_line() -> None:
    diff = (
        "--- a/m.py\n+++ b/m.py\n@@ -2 +2,2 @@ keep\n-last\n"
        "\\ No newline at end of file\n+last\n+++ b/other.py\n"
        "@@ -5 +6 @@ e\n-x\n+y\n"
    )

    assert changed_lines(diff) == {"m.py": (LineRange(2, 3), LineRange(6, 6))}


source_lines = st.lists(
    st.sampled_from(["a", "b", "c", "+++ b/x", "@@ -1 +1 @@", "\\ x"]), max_size=12
)


@given(source_lines, source_lines)
def test_changed_lines_are_the_lines_a_minimal_diff_inserts_or_replaces(
    old: list[str], new: list[str]
) -> None:
    diff = "".join(
        f"{line}\n"
        for line in difflib.unified_diff(old, new, "a/f.py", "b/f.py", n=0, lineterm="")
    )
    opcodes = difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes()
    expected = {
        line
        for tag, _, _, first, last in opcodes
        if tag in {"insert", "replace"}
        for line in range(first + 1, last + 1)
    }

    found = {
        line
        for lines in changed_lines(diff).values()
        for span in lines
        for line in range(span.first, span.last + 1)
    }

    assert found == expected


def mutant(file: str, line: int, status: Status, last: int | None = None) -> Mutant:
    return Mutant(file, LineRange(line, last or line), status, "Op", "a < b", "a <= b")


def assessed(report: Report) -> Assessed:
    assert isinstance(report.outcome, Assessed)
    return report.outcome


CHANGED = {DISK_PLAN: (LineRange(10, 12),), KIT: (LineRange(5, 5),)}


def test_only_mutants_overlapping_a_changed_line_are_counted() -> None:
    mutants = [
        mutant(DISK_PLAN, 9, "survived"),
        mutant(DISK_PLAN, 8, "killed", last=10),
        mutant(DISK_PLAN, 12, "survived"),
        mutant(DISK_PLAN, 13, "survived"),
        mutant(KIT, 5, "uncovered"),
        mutant("programs/claude-code/hook_event.py", 10, "survived"),
    ]

    report = mutation_diff(mutants, CHANGED, tool="t", head="h", mode=Diff("b"))

    assert assessed(report).totals == {
        "killed": 1,
        "survived": 1,
        "uncovered": 1,
        "timedOut": 0,
        "skipped": 0,
    }
    assert [(m.file, m.span.first) for m in assessed(report).listed] == [
        (KIT, 5),
        (DISK_PLAN, 12),
    ]


def test_killed_and_skipped_mutants_are_counted_but_not_listed() -> None:
    mutants = [mutant(DISK_PLAN, 10, "killed"), mutant(DISK_PLAN, 11, "skipped")]

    report = mutation_diff(mutants, CHANGED, tool="t", head="h", mode=Diff("b"))

    assert (assessed(report).totals["killed"], assessed(report).totals["skipped"]) == (
        1,
        1,
    )
    assert assessed(report).listed == ()


def test_the_json_is_schema_1_with_every_contract_key() -> None:
    report = mutation_diff(
        [mutant(DISK_PLAN, 11, "timedOut"), mutant(DISK_PLAN, 10, "killed")],
        CHANGED,
        tool="mutmut + StrykerJS",
        head="f" * 40,
        mode=Diff("e" * 40),
    )

    assert report_json(report) == {
        "schema": 1,
        "tool": "mutmut + StrykerJS",
        "head": "f" * 40,
        "base": "e" * 40,
        "totals": {
            "mutants": 2,
            "killed": 1,
            "survived": 0,
            "timedOut": 1,
            "uncovered": 0,
            "skipped": 0,
        },
        "mutants": [
            {
                "file": DISK_PLAN,
                "line": 11,
                "status": "timedOut",
                "operator": "Op",
                "original": "a < b",
                "replacement": "a <= b",
            }
        ],
        "notAssessed": "",
    }


def test_a_full_report_has_an_empty_base_in_the_json() -> None:
    report = mutation_diff([], CHANGED, tool="t", head="h", mode=Full())

    assert report_json(report) == {
        "schema": 1,
        "tool": "t",
        "head": "h",
        "base": "",
        "totals": {
            "mutants": 0,
            "killed": 0,
            "survived": 0,
            "uncovered": 0,
            "timedOut": 0,
            "skipped": 0,
        },
        "mutants": [],
        "notAssessed": "",
    }


def test_a_diff_outside_the_mutated_files_is_not_assessed() -> None:
    report = mutation_diff(
        [], {"README.md": (LineRange(1, 3),)}, tool="t", head="h", mode=Diff("b")
    )

    assert report_json(report) == {
        "schema": 1,
        "tool": "t",
        "head": "h",
        "base": "b",
        "totals": {
            "mutants": 0,
            "killed": 0,
            "survived": 0,
            "uncovered": 0,
            "timedOut": 0,
            "skipped": 0,
        },
        "mutants": [],
        "notAssessed": NOT_ASSESSED,
    }
    assert NOT_ASSESSED in render_markdown(report)


def test_a_diff_report_renders_its_base_head_totals_and_mutants() -> None:
    report = mutation_diff(
        [mutant(KIT, 5, "survived"), mutant(DISK_PLAN, 10, "killed")],
        CHANGED,
        tool="t",
        head="1234567" + "f" * 33,
        mode=Diff("abcdef0" + "e" * 33),
    )

    assert (
        render_markdown(report)
        == f"""\
**Mutation diff** (advisory): the lines changed since `abcdef0`, at `1234567`.

| Mutants | Killed | Survived | Uncovered | Timed out | Skipped |
| --- | --- | --- | --- | --- | --- |
| 2 | 1 | 1 | 0 | 0 | 0 |

```diff
@@ survived {KIT}:5 Op @@
- a < b
+ a <= b
```
"""
    )


def test_a_full_report_renders_every_mutated_line_and_its_totals() -> None:
    report = mutation_diff(
        [mutant(DISK_PLAN, 3, "killed"), mutant(KIT, 7, "timedOut")],
        {DISK_PLAN: (LineRange(1, 99),), KIT: (LineRange(1, 99),)},
        tool="t",
        head="1234567" + "f" * 33,
        mode=Full(),
    )

    assert (
        render_markdown(report)
        == f"""\
**Mutation diff** (advisory): every mutated line, at `1234567`.

| Mutants | Killed | Survived | Uncovered | Timed out | Skipped |
| --- | --- | --- | --- | --- | --- |
| 2 | 1 | 0 | 0 | 1 | 0 |

```diff
@@ timedOut {KIT}:7 Op @@
- a < b
+ a <= b
```
"""
    )


def fence(markdown: str) -> list[str]:
    """The lines a markdown viewer shows inside the diff fence: up to the first
    line that is a closing fence, as CommonMark reads it."""
    lines = markdown.split("\n")
    body = lines[lines.index("```diff") + 1 :]
    return body[
        : next(i for i, line in enumerate(body) if line.strip().startswith("```"))
    ]


def test_the_markdown_lists_each_mutant_with_its_place_and_both_sides() -> None:
    hostile = Mutant(
        KIT, LineRange(5, 6), "survived", "Op\n```", "a\n```\n<b>", "x\u2028y"
    )
    report = mutation_diff(
        [hostile], CHANGED, tool="t", head="h" * 40, mode=Diff("b" * 40)
    )

    markdown = render_markdown(report)

    assert fence(markdown) == [
        f"@@ survived {KIT}:5 Op ``` @@",
        "- a",
        "- ```",
        "- <b>",
        "+ x y",
    ]


@given(st.text())
def test_every_fenced_line_starts_with_a_diff_marker(text: str) -> None:
    report = mutation_diff(
        [Mutant(KIT, LineRange(5, 5), "uncovered", text, text, text)],
        CHANGED,
        tool="t",
        head="h",
        mode=Diff("b"),
    )

    assert all(line[:1] in {"@", "-", "+"} for line in fence(render_markdown(report)))


@given(st.text())
def test_one_line_never_holds_a_line_break(text: str) -> None:
    assert len(one_line(text).splitlines()) <= 1


USAGE = '''\
from dataclasses import dataclass


@dataclass(frozen=True)
class Usage:
    input: int = 0
    cache_read: int = 0
    cache_creation: int = 0
    output: int = 0

    def __add__(self, other: Usage) -> Usage:
        return Usage(
            self.input + other.input,
            self.cache_read + other.cache_read,
            self.cache_creation + other.cache_creation,
            other.output + self.output,
        )


# --- Window ---


def select_window(
    sessions: list[Session], since: datetime | None, project: str | None
) -> Window:
    """Sessions starting at or after the window start, the current run cut off at its invocation."""
    runs = sorted(
        ((ts, s) for s in sessions for ts in s.invocations), key=lambda run: run[0]
    )
    start = since.timestamp() if since else (runs[-2][0] if len(runs) > 1 else None)
    chosen = [
        s for s in sessions
    ]
    return chosen
'''

# What mutmut's get_diff_for_mutant printed for two mutants of USAGE.
ADD_DIFF = (
    "--- src/analyze.py\n+++ src/analyze.py\n@@ -3,5 +3,4 @@\n"
    "         self.input + other.input,\n"
    "         self.cache_read + other.cache_read,\n"
    "         self.cache_creation + other.cache_creation,\n"
    "-        other.output + self.output,\n"
    "-    )\n"
    "+        )"
)
WINDOW_DIFF = (
    "--- src/analyze.py\n+++ src/analyze.py\n@@ -6,7 +6,7 @@\n"
    " ) -> Window:\n"
    '     """Sessions starting at or after the window start, the current run cut off at its invocation."""\n'
    "     runs = sorted(\n"
    "-        ((ts, s) for s in sessions for ts in s.invocations), key=lambda run: run[0]\n"
    "+        None, key=lambda run: run[0]\n"
    "     )\n"
    "     start = since.timestamp() if since else (runs[-2][0] if len(runs) > 1 else None)\n"
    "     chosen = ["
)


def test_a_method_mutant_sits_on_the_lines_it_replaces() -> None:
    span = mutmut_span(ADD_DIFF, function_lines(USAGE)["Usage", "__add__"].first)

    assert (span.lines, span.original, span.replacement) == (
        LineRange(16, 17),
        "other.output + self.output,\n)",
        ")",
    )


def test_a_mutant_of_a_function_below_a_comment_sits_on_its_own_line() -> None:
    span = mutmut_span(WINDOW_DIFF, function_lines(USAGE)[None, "select_window"].first)

    assert (span.lines, span.original, span.replacement) == (
        LineRange(28, 28),
        "((ts, s) for s in sessions for ts in s.invocations), key=lambda run: run[0]",
        "None, key=lambda run: run[0]",
    )


def test_a_decorated_method_starts_at_its_first_decorator() -> None:
    source = "class C:\n    # why\n\n    @staticmethod\n    def m() -> int:\n        return 1\n"

    assert function_lines(source)["C", "m"].first == 2


def test_only_the_functions_holding_a_changed_line_are_selected() -> None:
    # Line 16 is in Usage.__add__, line 28 in select_window.
    assert changed_functions(USAGE, (LineRange(16, 16), LineRange(28, 28))) == [
        (None, "select_window"),
        ("Usage", "__add__"),
    ]


def test_a_change_outside_every_function_selects_none() -> None:
    # Line 1 is the import, 6-9 Usage's fields, 18-19 the blanks after __add__.
    changes = (LineRange(1, 1), LineRange(6, 9), LineRange(18, 19))

    assert changed_functions(USAGE, changes) == []


def test_a_method_of_a_nested_class_is_never_selected() -> None:
    # mutmut mutates no nested class, so there is nothing to run for it.
    source = (
        "class A:\n    class B:\n        def m(self) -> int:\n            return 1\n"
    )

    assert changed_functions(source, (LineRange(4, 4),)) == []


KIT_SOURCE = 'export function sizeLabel(size: number): string {\n  if (size > 1024) {\n    return "big";\n  }\n}\n'


def stryker_mutant(status: str) -> Json:
    return {
        "id": "1",
        "mutatorName": "EqualityOperator",
        "replacement": "size >= 1024",
        "status": status,
        "location": {
            "start": {"line": 2, "column": 7},
            "end": {"line": 2, "column": 18},
        },
    }


def test_stryker_mutants_are_read_by_repository_path_with_their_original_text() -> None:
    report: Json = {
        "schemaVersion": "2",
        "files": {
            "kit/index.ts": {
                "source": KIT_SOURCE,
                "mutants": [stryker_mutant("Survived")],
            }
        },
    }

    assert stryker_mutants(report) == [
        Mutant(
            KIT,
            LineRange(2, 2),
            "survived",
            "EqualityOperator",
            "size > 1024",
            "size >= 1024",
        )
    ]


def test_a_stryker_report_without_files_is_a_failed_run() -> None:
    with pytest.raises(RunFailedError):
        _ = stryker_mutants({"schemaVersion": "2"})


@pytest.mark.parametrize(
    ("word", "status"),
    [
        ("killed", "killed"),
        ("segfault", "killed"),
        ("survived", "survived"),
        ("no tests", "uncovered"),
        ("timeout", "timedOut"),
        ("suspicious", "timedOut"),
        ("skipped", "skipped"),
        ("caught by type check", "skipped"),
    ],
)
def test_mutmut_results_map_to_contract_statuses(word: str, status: Status) -> None:
    assert mutmut_status(word) == status


@pytest.mark.parametrize(
    ("word", "status"),
    [
        ("Killed", "killed"),
        ("Survived", "survived"),
        ("NoCoverage", "uncovered"),
        ("Timeout", "timedOut"),
        ("CompileError", "skipped"),
        ("RuntimeError", "skipped"),
        ("Ignored", "skipped"),
    ],
)
def test_stryker_results_map_to_contract_statuses(word: str, status: Status) -> None:
    assert stryker_status(word) == status


def test_a_mutant_mutmut_left_unrun_fails_the_run() -> None:
    with pytest.raises(RunFailedError):
        _ = mutmut_status("not checked")


def test_a_mutant_stryker_left_pending_fails_the_run() -> None:
    with pytest.raises(RunFailedError):
        _ = stryker_status("Pending")
