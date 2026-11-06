"""The command line's usage: bad argv exits 2 with a fix line, help prints."""

from pathlib import Path

import pytest

from state.state_fixtures import run


@pytest.mark.parametrize(
    "argv",
    [
        ("bogus",),
        ("init",),
        ("record",),
        ("record", "quality", "Great"),
        ("brief", "pm"),
    ],
)
def test_bad_usage_exits_2_with_a_fix_line(repo: Path, argv: tuple[str, ...]) -> None:
    code, out, err = run(repo, *argv)

    assert (code, out) == (2, "")
    assert err.splitlines()[1].startswith("fix: ")


def test_help_prints_usage_and_exits_0(repo: Path) -> None:
    code, out, err = run(repo, "help")

    assert (code, err) == (0, "")
    assert out.splitlines()[0] == (
        "state - record the engineer flow as events; advise the next arrow"
    )
    assert "  state next " in out
