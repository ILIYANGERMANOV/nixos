"""Black-box tests for pr-description's visible line count, run by `python-tests`.

Each test hands `count_visible` a PR body and asserts the number a reader sees
with every collapsed `<details>` reduced to its summary. One smoke test runs the
script as a bare-python subprocess, as the skill does.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from hypothesis import given
from hypothesis import strategies as st
from visible_lines import count_visible

SCRIPT = Path(__file__).with_name("visible_lines.py")
# Bare python, so an import outside the stdlib fails here as it would when deployed.
PYTHON = os.environ["STDLIB_PYTHON"]

# Markdown lines with no tag or backtick in them, so only the wrapping decides
# visibility.
plain_lines = st.lists(
    st.from_regex(r"[A-Za-z0-9 #*|-]{0,20}", fullmatch=True), max_size=8
)


def lines(*rows: str) -> str:
    return "\n".join(rows) + "\n"


def test_plain_body_counts_its_non_empty_lines() -> None:
    body = lines("## What & Why", "", "Adds X.", "   ", "## How")

    assert count_visible(body) == 3


def test_collapsed_block_counts_as_its_summary() -> None:
    body = lines(
        "## What & Why",
        "<details>",
        "<summary>Tests</summary>",
        "",
        "- one",
        "- two",
        "</details>",
    )

    assert count_visible(body) == 2


def test_one_line_collapsed_block_counts_as_one() -> None:
    body = lines(
        "<details><summary>Demo</summary> a video </details>", "Quality: Balanced"
    )

    assert count_visible(body) == 2


def test_open_block_shows_its_content() -> None:
    body = lines(
        "<details open>", "<summary>QA</summary>", "- pass", "- fail", "</details>"
    )

    assert count_visible(body) == 3


def test_collapsed_block_inside_an_open_one_counts_as_its_summary() -> None:
    body = lines(
        "<details open><summary>Outer</summary>",
        "shown",
        "<details><summary>Inner</summary>",
        "hidden",
        "</details>",
        "</details>",
    )

    assert count_visible(body) == 3


def test_everything_inside_a_collapsed_block_is_hidden() -> None:
    body = lines(
        "<details><summary>Outer</summary>",
        "<details open><summary>Inner</summary>",
        "hidden",
        "</details>",
        "hidden",
        "</details>",
    )

    assert count_visible(body) == 1


def test_tag_in_a_code_span_is_text() -> None:
    body = lines("Each section sits in a `<details>` block.", "Second line.")

    assert count_visible(body) == 2


def test_tags_in_a_fenced_block_are_text() -> None:
    body = lines(
        "````markdown",
        "<details><summary>Demo</summary>",
        "```sh",
        "run",
        "```",
        "</details>",
        "````",
    )

    assert count_visible(body) == 7


@given(before=plain_lines, hidden=plain_lines, after=plain_lines)
def test_collapsing_any_content_adds_exactly_the_summary(
    before: list[str], hidden: list[str], after: list[str]
) -> None:
    block = ["<details>", "<summary>Key decisions</summary>", *hidden, "</details>"]

    assert count_visible(lines(*before, *block, *after)) == (
        count_visible(lines(*before)) + 1 + count_visible(lines(*after))
    )


def test_script_prints_the_count_of_a_body_file(tmp_path: Path) -> None:
    body = tmp_path / "body.md"
    _ = body.write_text(
        lines(
            "## What & Why", "<details><summary>QA: Pass</summary>", "x", "</details>"
        )
    )

    run = subprocess.run(
        [PYTHON, "-I", str(SCRIPT), str(body)],
        capture_output=True,
        text=True,
        check=True,
    )

    assert run.stdout == "2\n"
