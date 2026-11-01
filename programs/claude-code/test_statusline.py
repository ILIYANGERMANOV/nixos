"""The statusline against what the shell scripts it replaced really printed.

statusline-corpus.json holds one run of those scripts per case, in both themes. A
case the new one answers differently carries its answer and why under `differs`.
"""

import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path
from typing import NotRequired, TypedDict, cast

import pytest
from hypothesis import given
from hypothesis import strategies as st
from statusline import DARK, LIGHT, Palette, Status, Unreadable, parse, render

STATUSLINE = os.environ["STATUSLINE"]
CORPUS = Path(__file__).with_name("statusline-corpus.json")

NOW = 1_800_000_000
# The longest an int gets through `json.loads`: Python refuses more digits.
LONGEST_INT = 10**4300 - 1
ANSI = re.compile(r"\x1b\[[0-9;]*m")
NO_TOOLS = Path("/nonexistent")
BRANCH_LINE = "\x1b[38;5;30mrepo\x1b[0m  \x1b[38;5;28mfeature/x\x1b[0m\n"


class Answer(TypedDict):
    dark: str
    light: str


class Difference(Answer):
    reason: str


class Case(Answer):
    name: str
    input: str
    now: int
    branch: str
    differs: NotRequired[Difference]


type Doc = dict[str, object]

CASES = cast("list[Case]", json.loads(CORPUS.read_text(encoding="utf-8")))


def printed(raw: str, palette: Palette, branch: str = "", now: int = NOW) -> str:
    """What the entry point writes for this input."""
    match parse(raw):
        case Unreadable():
            return ""
        case Status() as status:
            line = render(status, branch, now, palette)
            return f"{line}\n".encode(errors="replace").decode()


def plain(doc: Doc) -> str:
    return ANSI.sub("", printed(json.dumps(doc), DARK))


def rate_limit(percent: float, resets_at: int | None = None) -> Doc:
    five_hour = {"used_percentage": percent, "resets_at": resets_at}
    return {"rate_limits": {"five_hour": five_hour}}


def context(size: int, percent: float) -> Doc:
    return {"context_window": {"context_window_size": size, "used_percentage": percent}}


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_prints_what_the_shell_scripts_printed(case: Case) -> None:
    expected = case.get("differs", case)

    assert printed(case["input"], DARK, case["branch"], case["now"]) == expected["dark"]
    assert (
        printed(case["input"], LIGHT, case["branch"], case["now"]) == expected["light"]
    )


def test_every_difference_says_why() -> None:
    differences = [case for case in CASES if "differs" in case]

    assert len(differences) == 9
    assert all(case["differs"]["reason"] for case in differences)


@given(st.floats(0, 100))
def test_the_bar_keeps_its_width_and_shows_the_nearest_percent(percent: float) -> None:
    match = re.fullmatch(r"  ([▓░]+) (\d+)%\n", plain(rate_limit(percent)))

    assert match is not None
    assert len(match[1]) == 5
    assert abs(int(match[2]) - percent) <= 0.5


@given(st.floats(0, 100), st.floats(0, 100))
def test_the_bar_never_shrinks_as_usage_grows(a: float, b: float) -> None:
    low, high = sorted((a, b))

    assert plain(rate_limit(low)).count("▓") <= plain(rate_limit(high)).count("▓")


@given(st.integers(1, 1000), st.integers(0, 59))
def test_a_countdown_adds_up_to_the_whole_minutes_left(
    minutes: int, spare_seconds: int
) -> None:
    resets_at = NOW + minutes * 60 + spare_seconds

    shown = re.search(r"\(reset (?:(\d+)h)?(\d+)m\)", plain(rate_limit(1, resets_at)))

    assert shown is not None
    assert int(shown[1] or 0) * 60 + int(shown[2]) == minutes
    assert int(shown[2]) < 60 or shown[1] is None


@given(st.integers(0, 59))
def test_under_a_minute_left_shows_no_countdown(spare_seconds: int) -> None:
    assert "reset" not in plain(rate_limit(1, NOW + spare_seconds))


@given(st.integers(-(10**9), NOW))
def test_a_reset_in_the_past_shows_no_countdown(resets_at: int) -> None:
    assert "reset" not in plain(rate_limit(1, resets_at))


@given(st.integers(0, 10**7), st.integers(0, 100))
def test_tokens_are_the_share_of_the_window_rounded_down(
    size: int, percent: int
) -> None:
    shown = re.search(r"(\d+)k / (\d+)k \((\d+)%\)", plain(context(size, percent)))

    assert shown is not None
    used_k, size_k, shown_percent = map(int, shown.groups())
    assert shown_percent == percent
    assert size_k * 1000 <= size < (size_k + 1) * 1000
    assert used_k * 100_000 <= size * percent < (used_k + 1) * 100_000


@given(st.integers(0, 10**7), st.integers(0, 100), st.integers(0, 100))
def test_each_part_prints_the_same_with_or_without_the_others(
    size: int, used: int, limit: int
) -> None:
    model: Doc = {"model": {"id": "m"}}
    parts = (model, rate_limit(limit), context(size, used))

    alone = "".join(plain(part).removesuffix("\n") for part in parts)

    assert plain(model | rate_limit(limit) | context(size, used)) == f"{alone}\n"


json_values = st.recursive(
    st.none()
    | st.booleans()
    | st.integers()
    | st.floats()
    | st.text(max_size=8)
    | st.sampled_from(["", "abc", "62.5", "-1", "1e3", "NaN", "\0", "\ud800"]),
    lambda children: (
        st.lists(children, max_size=2)
        | st.dictionaries(st.text(max_size=4), children, max_size=2)
    ),
    max_leaves=6,
)
fields = st.sampled_from(
    [
        "workspace",
        "model",
        "rate_limits",
        "context_window",
    ]
)
nested_fields = st.sampled_from(
    [
        ("workspace", "current_dir"),
        ("model", "display_name"),
        ("context_window", "context_window_size"),
        ("context_window", "used_percentage"),
    ]
)


@given(st.text())
def test_no_text_raises(raw: str) -> None:
    assert isinstance(printed(raw, DARK), str)


@given(st.dictionaries(fields, json_values))
def test_no_shape_of_a_top_level_field_raises(doc: Doc) -> None:
    assert isinstance(printed(json.dumps(doc), DARK), str)


@given(nested_fields, json_values, json_values)
def test_no_value_of_a_field_raises(
    path: tuple[str, str], value: object, percent: object
) -> None:
    usage = {"five_hour": {"used_percentage": percent, "resets_at": value}}
    doc = {path[0]: {path[1]: value}, "rate_limits": usage}

    assert isinstance(printed(json.dumps(doc), DARK), str)


def test_json_nested_past_the_recursion_limit_is_unreadable() -> None:
    assert printed("[" * 200_000, DARK) == ""


def test_a_huge_percentage_is_unreadable() -> None:
    assert plain(rate_limit(1e7)) == ""


@given(st.integers(10**18, LONGEST_INT))
def test_a_huge_window_size_is_unreadable(size: int) -> None:
    assert plain(context(size, 99)) == ""


@given(st.integers(10**18, LONGEST_INT))
def test_a_huge_reset_time_loses_only_the_countdown(resets_at: int) -> None:
    assert plain(rate_limit(1, resets_at)) == "  ░░░░░ 1%\n"


def run(stdin: str | None, path: Path = NO_TOOLS) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [STATUSLINE],
        input=stdin,
        stdin=subprocess.DEVNULL if stdin is None else None,
        capture_output=True,
        check=False,
        text=True,
        env={"PATH": str(path)},
    )


def git(repo: Path, *args: str) -> None:
    identity = ("-c", "user.name=t", "-c", "user.email=t@t")
    _ = subprocess.run(["git", "-C", repo, *identity, *args], check=True)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    path = tmp_path / "repo"
    path.mkdir()
    git(path, "init", "--quiet", "--initial-branch=feature/x")
    return path


def at(path: Path) -> str:
    return json.dumps({"cwd": str(path)})


def test_shows_the_branch_of_a_real_repository(repo: Path) -> None:
    git(repo, "commit", "--quiet", "--allow-empty", "--message=c")

    assert run(at(repo)).stdout == BRANCH_LINE


def test_shows_the_branch_of_a_repository_with_no_commit(repo: Path) -> None:
    assert run(at(repo)).stdout == BRANCH_LINE


def test_shows_the_short_commit_on_a_detached_head(repo: Path) -> None:
    git(repo, "commit", "--quiet", "--allow-empty", "--message=c")
    git(repo, "checkout", "--quiet", "--detach")

    assert re.fullmatch(r"repo  [0-9a-f]{7,}\n", ANSI.sub("", run(at(repo)).stdout))


def test_shows_only_the_directory_outside_a_repository(tmp_path: Path) -> None:
    assert ANSI.sub("", run(at(tmp_path / "gone")).stdout) == "gone\n"


def test_uses_the_clock_for_the_countdown() -> None:
    far_future = ANSI.sub("", run(json.dumps(rate_limit(1, 2**40))).stdout)
    long_past = ANSI.sub("", run(json.dumps(rate_limit(1, 1_700_000_000))).stdout)

    assert "(reset " in far_future
    assert long_past == "  ░░░░░ 1%\n"


@pytest.mark.parametrize(
    ("stdin", "stdout"),
    [
        (None, "\n"),
        ("", "\n"),
        ("{not json", ""),
        ("[1]", ""),
        ('{"context_window": {"context_window_size": "x", "used_percentage": 1}}', ""),
        (
            '{"context_window": {"context_window_size": 1e400, "used_percentage": 1}}',
            "",
        ),
        (
            '{"context_window": {"context_window_size": 1, "used_percentage": 1e400}}',
            "",
        ),
        ('{"rate_limits": {"five_hour": {"used_percentage": 1e400}}}', ""),
    ],
)
def test_bad_input_exits_clean_with_no_traceback(
    stdin: str | None, stdout: str
) -> None:
    done = run(stdin)

    assert (done.returncode, done.stdout, done.stderr) == (0, stdout, "")


def test_tokens_past_the_digits_python_prints_exit_clean() -> None:
    done = run(json.dumps(context(LONGEST_INT, 1_000_000)))

    assert (done.returncode, done.stdout, done.stderr) == (0, "", "")


def test_a_cwd_past_the_kernels_argument_limit_prints_its_name() -> None:
    name = "x" * 200_000

    done = run(json.dumps({"cwd": f"/{name}"}))

    assert (done.returncode, ANSI.sub("", done.stdout), done.stderr) == (
        0,
        f"{name}\n",
        "",
    )


def test_a_long_cwd_the_kernel_still_resolves_shows_its_branch(repo: Path) -> None:
    nested = f"{repo}{'/.' * ((4000 - len(str(repo))) // 2)}"

    assert ANSI.sub("", run(json.dumps({"cwd": nested})).stdout) == ".  feature/x\n"


def test_a_closed_stdin_prints_an_empty_line() -> None:
    done = subprocess.run(
        ["sh", "-c", f"exec {STATUSLINE} <&-"], capture_output=True, check=False
    )

    assert (done.returncode, done.stdout, done.stderr) == (0, b"\n", b"")


SH = shutil.which("sh")


def fake_tool(directory: Path, name: str, output: str) -> None:
    tool = directory / name
    _ = tool.write_text(f"#!{SH}\necho '{output}'\n", encoding="utf-8")
    tool.chmod(tool.stat().st_mode | stat.S_IXUSR)


@pytest.mark.parametrize(
    ("tools", "color"),
    [
        ({}, LIGHT.cyan),
        ({"gsettings": "'prefer-dark'"}, DARK.cyan),
        ({"gsettings": "'default'"}, LIGHT.cyan),
        ({"defaults": "Dark"}, DARK.cyan),
        ({"defaults": "Light", "gsettings": "'prefer-dark'"}, LIGHT.cyan),
    ],
)
def test_auto_theme_follows_the_system_appearance(
    tmp_path: Path, tools: dict[str, str], color: str
) -> None:
    for name, output in tools.items():
        fake_tool(tmp_path, name, output)

    assert run('{"cwd": "/a"}', tmp_path).stdout == f"{color}a\x1b[0m\n"
