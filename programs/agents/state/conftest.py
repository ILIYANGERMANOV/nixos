"""The fixtures the command-line tests share: a temp git repo, and GitHub as a
fake `gh` on PATH, holding draft PR 7 from `feature`, the repo's branch, to main."""

import os
from pathlib import Path

import pytest

from state.state_fixtures import GitHub, make_repo


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    return make_repo(tmp_path)


@pytest.fixture(autouse=True)
def github(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> GitHub:
    """No test reaches the real GitHub: the sandbox has no network."""
    bin_dir = tmp_path / "gh-bin"
    bin_dir.mkdir()
    hub = GitHub(tmp_path / "github.json")
    hub.install(bin_dir)
    hub.open()
    monkeypatch.setenv("FAKE_GITHUB", str(hub.world))
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    return hub
