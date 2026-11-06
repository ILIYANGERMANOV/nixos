"""The entry point prints what a command returns."""

from pathlib import Path

from state.core import render
from state.state_fixtures import ok


def test_render_prints_the_states_block(repo: Path) -> None:
    assert ok(repo, "render") == render()
