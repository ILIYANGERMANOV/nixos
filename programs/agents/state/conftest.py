"""The temp git repo fixture the command-line tests share."""

from pathlib import Path

import pytest
from state_fixtures import make_repo


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    return make_repo(tmp_path)
