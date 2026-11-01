"""The guard against the real denylist, and through its entry point with a fake nix.

Both silent failures live here: a denylist that matches nothing and a plan reader
that yields nothing would each report every plan as clean.
"""

import os
import subprocess
from pathlib import Path

import pytest
from cache_check import Clean, Denied, Denylist, Unusable, judge, parse_denylist
from hypothesis import given
from hypothesis import strategies as st

PYTHON = os.environ["STDLIB_PYTHON"]
MODULE = Path(__file__).with_name("cache_check.py")
REAL_DENYLIST = Path(__file__).with_name("expensive-builds.deny")

SWIFT = "swift-5.10.1.drv"
CARGO_TARBALL = "cargo-1.96.1-aarch64-apple-darwin.drv"
GHC = "ghc-9.10.3"

names = st.text(st.sampled_from("abcdefgxyz0123456789+._-"), min_size=1, max_size=20)


def store_entry(name: str) -> str:
    return f"  /nix/store/{'a' * 32}-{name}"


def plan(built: list[str], fetched: list[str] | None = None) -> str:
    sections = [f"these {len(built)} derivations will be built:"] if built else []
    sections += [store_entry(name) for name in built]
    if fetched:
        sections.append(
            f"these {len(fetched)} paths will be fetched (1.0 GiB download, 2.0 GiB unpacked):"
        )
        sections += [store_entry(name) for name in fetched]
    return "\n".join(sections) + "\n"


def denylist_of(text: str) -> Denylist:
    parsed = parse_denylist(text)
    assert isinstance(parsed, Denylist)
    return parsed


def real_denylist() -> Denylist:
    return denylist_of(REAL_DENYLIST.read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    "name",
    [
        SWIFT,
        "swiftpm-5.10.1.drv",
        "dotnet-sdk-9.0.100.drv",
        "ghc-9.10.3.drv",
        "ghcide-2.9.0.drv",
        "haskell-language-server-2.9.0.drv",
        "hls-plugin-api-2.9.drv",
        "llvm-19.1.7.drv",
        "clang-unwrapped-19.1.7.drv",
        "clang-19.1.7.drv",
        "nodejs-24.21.0.drv",
        "go-1.24.3.drv",
        "zig-0.14.0.drv",
        "openjdk-21.0.7.drv",
        "rustc-1.96.1.drv",
        "cargo-1.96.1.drv",
        "chromium-140.0.drv",
        "electron-37.2.0.drv",
        "webkitgtk-2.48.drv",
        "qtbase-6.9.drv",
        "qtwebengine-6.9.drv",
        "texlive-2025.drv",
        "boost-1.87.0.drv",
    ],
)
def test_the_real_denylist_refuses_an_expensive_build(name: str) -> None:
    assert judge(plan([name]), real_denylist()) == Denied((name,))


@pytest.mark.parametrize(
    "name",
    [
        CARGO_TARBALL,
        "rustc-1.96.1-aarch64-apple-darwin.drv",
        "clang-wrapper-19.1.7.drv",
        "hello-swift-1.0.drv",
        "pkg-config-go-1.2.drv",
    ],
)
def test_the_real_denylist_lets_a_cheap_lookalike_through(name: str) -> None:
    assert judge(plan([name]), real_denylist()) == Clean()


def test_a_denied_name_counts_only_when_built_not_fetched() -> None:
    given_plan = plan([SWIFT, CARGO_TARBALL], [GHC])

    assert judge(given_plan, real_denylist()) == Denied((SWIFT,))


def test_a_build_after_the_fetch_section_still_counts() -> None:
    given_plan = plan([], [GHC]) + plan([SWIFT])

    assert judge(given_plan, real_denylist()) == Denied((SWIFT,))


@pytest.mark.parametrize(
    ("name", "given_plan"),
    [
        ("nothing to do prints no plan at all", ""),
        (
            "auto-GC noise names store paths, unindented",
            f"running auto-GC to free 1 bytes\ndeleting '/nix/store/{'a' * 32}-{SWIFT}'\n",
        ),
        ("a fetch-only plan", plan([], [GHC, SWIFT])),
        (
            "a warning around a clean plan",
            f"warning: Git tree is dirty\n{plan(['hello-2.12.drv'])}",
        ),
        (
            "singular headers",
            f"this derivation will be built:\n{store_entry('hello-2.12.drv')}\nthis path will be fetched (1.0 MiB download):\n{store_entry(GHC)}\n",
        ),
    ],
)
def test_a_plan_that_builds_nothing_denied_is_clean(name: str, given_plan: str) -> None:
    assert judge(given_plan, real_denylist()) == Clean(), name


@pytest.mark.parametrize(
    ("name", "given_plan"),
    [
        ("a header with no entries", "these 2 derivations will be built:\n"),
        (
            "entries nix stopped indenting",
            f"these 1 derivations will be built:\n{store_entry(SWIFT).strip()}\n",
        ),
        (
            "an entry that is no longer a bare store path",
            f"these 1 derivations will be built:\n{store_entry(SWIFT)} (aarch64-darwin)\n",
        ),
        (
            "a good entry beside one that is not",
            f"these 2 derivations will be built:\n{store_entry(SWIFT)}\n  swift-6.0.drv\n",
        ),
        (
            "a fetch section that is not a list",
            f"{plan(['hello-2.12.drv'])}these 1 paths will be fetched (1 GiB):\n  ???\n",
        ),
        (
            "a reworded header leaves its entries stray",
            f"the following derivations would be built:\n{store_entry(SWIFT)}\n",
        ),
    ],
)
def test_an_unreadable_plan_is_never_clean(name: str, given_plan: str) -> None:
    verdict = judge(given_plan, real_denylist())

    assert isinstance(verdict, Unusable), name


@pytest.mark.parametrize(
    ("name", "text"),
    [
        ("an empty file", ""),
        ("only comments and blanks", "# all\n\n   \n  # gone\n"),
        ("a broken regex", "^swift\n^(unclosed\n"),
        ("a POSIX class re would not honour", "^llvm-[[:digit:]]\n"),
    ],
)
def test_a_denylist_that_cannot_match_is_refused(name: str, text: str) -> None:
    assert isinstance(parse_denylist(text), Unusable), name


def test_comments_and_blank_lines_are_not_patterns() -> None:
    denylist = denylist_of("# ^hello\n\n   # ^hello\n  \n^swift\n")

    assert judge(plan(["hello-2.12.drv"]), denylist) == Clean()


def test_a_pattern_anchors_on_the_name_not_the_store_path() -> None:
    denylist = denylist_of("^swift\n")

    assert judge(plan([SWIFT]), denylist) == Denied((SWIFT,))


def test_a_trailing_anchor_reaches_the_end_of_the_name() -> None:
    denylist = denylist_of(r"^cargo-[0-9.]+\.drv$")

    assert judge(plan([CARGO_TARBALL, "cargo-1.96.1.drv"]), denylist) == Denied(
        ("cargo-1.96.1.drv",)
    )


def test_an_unanchored_pattern_matches_mid_name() -> None:
    denylist = denylist_of(r"go-1\.")

    assert judge(plan([CARGO_TARBALL]), denylist) == Denied((CARGO_TARBALL,))


def test_a_denied_entry_keeps_every_match_in_plan_order() -> None:
    denylist = denylist_of("^ghc-\n^swift\n")

    assert judge(plan([SWIFT, "hello.drv", "ghc-9.drv"]), denylist) == Denied(
        (SWIFT, "ghc-9.drv")
    )


def denied_names(built: list[str]) -> tuple[str, ...]:
    """Empty when clean: a generated plan is always readable, which the assert pins."""
    verdict = judge(plan(built), denylist_of("^a\n[0-9]$\n"))
    assert not isinstance(verdict, Unusable)
    return verdict.names if isinstance(verdict, Denied) else ()


@given(st.lists(names), st.lists(names))
def test_a_plan_is_judged_entry_by_entry(left: list[str], right: list[str]) -> None:
    assert denied_names(left + right) == denied_names(left) + denied_names(right)


@given(st.lists(names, min_size=1), st.lists(names, min_size=1))
def test_fetched_paths_never_change_the_verdict(
    built: list[str], fetched: list[str]
) -> None:
    denylist = denylist_of("^a\n")

    assert judge(plan(built, fetched), denylist) == judge(plan(built), denylist)


@given(st.lists(names), names, st.lists(names))
def test_a_denied_build_is_found_wherever_it_sits(
    before: list[str], suffix: str, after: list[str]
) -> None:
    denied = f"swift{suffix}"

    verdict = judge(plan([*before, denied, *after]), denylist_of("^swift\n"))

    assert isinstance(verdict, Denied)
    assert denied in verdict.names


@given(st.lists(names, min_size=1), st.lists(names))
def test_a_section_stripped_of_its_entries_is_never_clean(
    built: list[str], fetched: list[str]
) -> None:
    header, *_ = plan(built).splitlines()

    verdict = judge(f"{header}\n{plan([], fetched)}", denylist_of("^a\n"))

    assert isinstance(verdict, Unusable)


def run_guard(
    tmp_path: Path,
    plan_text: str,
    nix_exit: int = 0,
    denylist: str = "^swift\n",
) -> subprocess.CompletedProcess[str]:
    """Runs the module as `just` does, with a nix that accepts only the guard's call."""
    nix = tmp_path / "nix"
    _ = nix.write_text(
        f"""#!/bin/sh
[ "$*" = "build --dry-run .#host" ] || exit 99
cat "{tmp_path}/plan" >&2
exit {nix_exit}
""",
        encoding="utf-8",
    )
    nix.chmod(0o755)
    _ = (tmp_path / "plan").write_text(plan_text, encoding="utf-8")
    deny = tmp_path / "deny"
    _ = deny.write_text(denylist, encoding="utf-8")

    return subprocess.run(
        [PYTHON, MODULE, "guard", ".#host", deny],
        capture_output=True,
        text=True,
        check=False,
        env={"PATH": f"{tmp_path}:{os.environ['PATH']}"},
    )


def test_a_clean_plan_exits_0(tmp_path: Path) -> None:
    result = run_guard(tmp_path, plan(["hello-2.12.drv"], [GHC]))

    assert result.returncode == 0
    assert result.stdout == (
        "these 1 derivations will be built:\n"
        "these 1 paths will be fetched (1.0 GiB download, 2.0 GiB unpacked):\n"
        "guard: nothing on the denylist would be built.\n"
    )


def test_a_denied_plan_exits_1_naming_the_builds(tmp_path: Path) -> None:
    result = run_guard(tmp_path, plan([SWIFT, "hello-2.12.drv"]))

    assert result.returncode == 1
    assert f"\n  {SWIFT}\n" in result.stderr
    assert "hello" not in result.stderr
    assert "nothing on the denylist" not in result.stdout


def test_an_unreadable_plan_exits_1(tmp_path: Path) -> None:
    result = run_guard(tmp_path, "these 2 derivations will be built:\n")

    assert result.returncode == 1
    assert "cannot vouch" in result.stderr


def test_a_failing_nix_exits_1_and_shows_its_output(tmp_path: Path) -> None:
    result = run_guard(tmp_path, "error: flake has no such attribute\n", nix_exit=3)

    assert result.returncode == 1
    assert "nix exited 3" in result.stderr
    assert "no such attribute" in result.stderr


def test_a_broken_denylist_exits_1_on_a_clean_plan(tmp_path: Path) -> None:
    result = run_guard(tmp_path, plan(["hello-2.12.drv"]), denylist="^(unclosed\n")

    assert result.returncode == 1
    assert "bad denylist pattern" in result.stderr
