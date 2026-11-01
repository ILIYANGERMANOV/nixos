"""The decisions behind free-disk and factory-gc. Unknown never deletes."""

from dataclasses import replace
from pathlib import Path, PurePath

from disk_plan import (
    DAY_SECONDS,
    Absent,
    GcRoot,
    Keep,
    Kind,
    ListedWorktree,
    LocalWork,
    Policy,
    Probe,
    QaRun,
    Remove,
    ResultLink,
    Stat,
    Unknown,
    Worktree,
    decide_cache,
    decide_own_stale_root,
    decide_qa_run,
    decide_stale_root,
    decide_worktree,
    local_work_phrases,
    parse_count,
    parse_pids,
    parse_worktrees,
    read_local_work,
    read_newest_write,
    read_probe,
    read_result_link,
)
from hypothesis import given
from hypothesis import strategies as st

NOW = 1_000_000.0
UID = 1000
REPOSITORY = PurePath("/home/agent/repos/shop")
WORKTREE = REPOSITORY / ".claude/worktrees/task"
CLEAN = LocalWork(uncommitted=0, unpushed=0)
NO_SESSIONS: frozenset[PurePath] = frozenset()
TMP = PurePath("/scratch")
LINK_PATH = TMP / "build/result"
ENTRY = PurePath("/nix/var/nix/gcroots/auto/abc")
CACHE = PurePath("/home/agent/.cache")
KEPT_FOR_BUILDS = {CACHE / "nix", CACHE / "cabal", CACHE / "qa"}
RUN = PurePath("/home/agent/.cache/qa/owner/repo/runs/12")
UNKNOWN = Unknown("a fact")

names = st.text(st.characters(exclude_characters="/\0"), min_size=1).filter(
    lambda name: name not in {".", ".."}
)
relative_paths = st.lists(names, max_size=3).map(lambda parts: PurePath(*parts))
counts = st.integers(min_value=0, max_value=1000)
facts_about_counts = st.one_of(counts, st.just(UNKNOWN))
ages = st.floats(min_value=-DAY_SECONDS, max_value=10 * DAY_SECONDS)
kinds = st.sampled_from(Kind)
listed_worktrees = st.builds(
    ListedWorktree, relative_paths.map(PurePath("/").joinpath), locked=st.booleans()
)
probes = st.one_of(
    st.just(Absent()),
    st.just(UNKNOWN),
    st.builds(Stat, kinds, st.just(NOW), st.integers(min_value=0, max_value=2000)),
)


def stat_of(kind: Kind, age: float = 0.0, uid: int = UID) -> Stat:
    return Stat(kind, NOW - age, uid)


def worktree(
    path: PurePath = WORKTREE,
    work: LocalWork = CLEAN,
    *,
    locked: bool = False,
) -> Worktree:
    return Worktree(path, REPOSITORY, locked, work)


def gc_root(
    path: PurePath = LINK_PATH,
    probe: Probe | None = None,
    resolved_parent: PurePath | Unknown | None = None,
) -> GcRoot:
    link = ResultLink(
        path,
        path.parent if resolved_parent is None else resolved_parent,
        stat_of(Kind.SYMLINK, 3 * DAY_SECONDS) if probe is None else probe,
    )
    return GcRoot(ENTRY, link)


def test_a_clean_pushed_sessionless_worktree_goes() -> None:
    assert decide_worktree(worktree(), NO_SESSIONS) == Remove(WORKTREE)


def test_the_main_checkout_stays() -> None:
    decision = decide_worktree(worktree(REPOSITORY), NO_SESSIONS)

    assert decision == Keep(REPOSITORY, Policy.MAIN_CHECKOUT)


def test_a_run_s_worktree_outside_the_repository_stays() -> None:
    path = PurePath("/home/agent/.10x/run/worktrees/task")

    assert decide_worktree(worktree(path), NO_SESSIONS) == Keep(
        path, Policy.OUTSIDE_REPOSITORY
    )


def test_a_sibling_directory_with_the_same_prefix_is_outside_the_repository() -> None:
    path = PurePath("/home/agent/repos/shop-old/worktree")

    assert decide_worktree(worktree(path), NO_SESSIONS) == Keep(
        path, Policy.OUTSIDE_REPOSITORY
    )


def test_a_locked_worktree_stays() -> None:
    assert decide_worktree(worktree(locked=True), NO_SESSIONS) == Keep(
        WORKTREE, Policy.LOCKED
    )


def test_a_session_in_a_subdirectory_keeps_the_worktree() -> None:
    sessions = frozenset({WORKTREE / "src/deep"})

    assert decide_worktree(worktree(), sessions) == Keep(WORKTREE, Policy.LIVE_SESSION)


def test_a_session_in_a_directory_sharing_the_prefix_does_not_keep_the_worktree() -> (
    None
):
    sessions = frozenset({WORKTREE.with_name("task-2")})

    assert decide_worktree(worktree(), sessions) == Remove(WORKTREE)


def test_an_unknown_session_list_keeps_the_worktree() -> None:
    assert decide_worktree(worktree(), UNKNOWN) == Keep(WORKTREE, UNKNOWN)


@given(relative_paths, facts_about_counts, facts_about_counts)
def test_a_live_session_s_root_is_never_removed(
    below: PurePath, uncommitted: int | Unknown, unpushed: int | Unknown
) -> None:
    work = LocalWork(uncommitted, unpushed)

    decision = decide_worktree(worktree(work=work), frozenset({WORKTREE / below}))

    assert isinstance(decision, Keep)


@given(relative_paths, facts_about_counts, facts_about_counts)
def test_unread_or_nonzero_local_work_is_never_removed(
    below: PurePath, uncommitted: int | Unknown, unpushed: int | Unknown
) -> None:
    decision = decide_worktree(
        worktree(REPOSITORY / below, LocalWork(uncommitted, unpushed)), NO_SESSIONS
    )

    if isinstance(decision, Remove):
        assert (uncommitted, unpushed) == (0, 0)


@given(relative_paths)
def test_a_worktree_is_removed_exactly_when_inside_its_repository(
    below: PurePath,
) -> None:
    decision = decide_worktree(worktree(REPOSITORY / below), NO_SESSIONS)

    assert isinstance(decision, Remove) == (below != PurePath())


def test_local_work_names_what_is_at_risk() -> None:
    phrases = local_work_phrases(LocalWork(uncommitted=2, unpushed=1))

    assert phrases == ("2 uncommitted file(s)", "1 unpushed commit(s)")


def test_clean_local_work_says_nothing() -> None:
    assert local_work_phrases(CLEAN) == ()


@given(facts_about_counts, facts_about_counts)
def test_local_work_is_silent_only_when_known_clean(
    uncommitted: int | Unknown, unpushed: int | Unknown
) -> None:
    phrases = local_work_phrases(LocalWork(uncommitted, unpushed))

    assert (phrases == ()) == ((uncommitted, unpushed) == (0, 0))


def test_a_throwaway_cache_goes() -> None:
    path = CACHE / "npm"

    assert decide_cache(path, stat_of(Kind.DIRECTORY), KEPT_FOR_BUILDS) == Remove(path)


def test_a_loose_file_in_the_cache_goes() -> None:
    path = CACHE / "stray.log"

    assert decide_cache(path, stat_of(Kind.FILE), KEPT_FOR_BUILDS) == Remove(path)


def test_a_cache_that_keeps_builds_fast_stays() -> None:
    path = CACHE / "nix"

    decision = decide_cache(path, stat_of(Kind.DIRECTORY), KEPT_FOR_BUILDS)

    assert decision == Keep(path, Policy.KEEPS_BUILDS_FAST)


def test_a_symlink_in_the_cache_stays() -> None:
    path = CACHE / "shell"

    decision = decide_cache(path, stat_of(Kind.SYMLINK), KEPT_FOR_BUILDS)

    assert decision == Keep(path, Policy.GC_ROOT)


def test_a_cache_that_is_not_there_has_nothing_to_remove() -> None:
    path = CACHE / "cabal/logs"

    assert decide_cache(path, Absent(), KEPT_FOR_BUILDS) == Keep(path, Policy.GONE)


def test_a_cache_that_cannot_be_read_stays() -> None:
    path = CACHE / "npm"

    assert decide_cache(path, UNKNOWN, KEPT_FOR_BUILDS) == Keep(path, UNKNOWN)


@given(st.sampled_from(sorted(KEPT_FOR_BUILDS)), probes)
def test_a_protected_cache_is_never_removed(path: PurePath, probe: Probe) -> None:
    assert isinstance(decide_cache(path, probe, KEPT_FOR_BUILDS), Keep)


@given(names, probes)
def test_only_a_known_plain_visible_entry_is_removed(name: str, probe: Probe) -> None:
    decision = decide_cache(CACHE / name, probe, KEPT_FOR_BUILDS)

    known = isinstance(probe, Stat) and probe.kind is not Kind.SYMLINK
    assert isinstance(decision, Remove) == (known and not name.startswith("."))


def qa_run(age: float, probe: Probe | None = None) -> QaRun:
    return QaRun(RUN, stat_of(Kind.DIRECTORY) if probe is None else probe, NOW - age)


def test_a_run_quiet_for_over_a_day_goes() -> None:
    assert decide_qa_run(qa_run(DAY_SECONDS + 1), NOW) == Remove(RUN)


def test_a_run_written_within_the_day_stays() -> None:
    assert decide_qa_run(qa_run(DAY_SECONDS - 1), NOW) == Keep(RUN, Policy.RECENT)


def test_a_run_with_an_unreadable_tree_stays() -> None:
    run = replace(qa_run(2 * DAY_SECONDS), newest_write=UNKNOWN)

    assert decide_qa_run(run, NOW) == Keep(RUN, UNKNOWN)


def test_a_symlink_among_the_runs_stays() -> None:
    run = qa_run(2 * DAY_SECONDS, stat_of(Kind.SYMLINK))

    assert decide_qa_run(run, NOW) == Keep(RUN, Policy.NOT_A_RUN)


@given(ages, probes)
def test_a_run_is_removed_only_when_a_known_directory_quiet_for_a_day(
    age: float, probe: Probe
) -> None:
    decision = decide_qa_run(qa_run(age, probe), NOW)

    directory = isinstance(probe, Stat) and probe.kind is Kind.DIRECTORY
    assert isinstance(decision, Remove) == (directory and age >= DAY_SECONDS)


def test_a_stale_root_is_unregistered() -> None:
    assert decide_stale_root(gc_root(), {TMP}, NOW) == Remove(ENTRY)


def test_a_fresh_root_stays() -> None:
    root = gc_root(probe=stat_of(Kind.SYMLINK, 2 * DAY_SECONDS - 1))

    assert decide_stale_root(root, {TMP}, NOW) == Keep(ENTRY, Policy.RECENT)


def test_a_root_outside_the_temporary_directories_stays() -> None:
    root = gc_root(PurePath("/home/agent/.gcroots/shop/wt"))

    assert decide_stale_root(root, {TMP}, NOW) == Keep(
        ENTRY, Policy.OUTSIDE_DIRECTORIES
    )


def test_a_profile_generation_stays_however_old() -> None:
    root = gc_root(TMP / "shell-12-link")

    assert decide_stale_root(root, {TMP}, NOW) == Keep(ENTRY, Policy.PROFILE_GENERATION)


def test_a_result_link_named_only_like_a_link_goes() -> None:
    assert decide_stale_root(gc_root(TMP / "result-link"), {TMP}, NOW) == Remove(ENTRY)


def test_a_root_whose_parent_resolves_elsewhere_stays() -> None:
    root = gc_root(resolved_parent=PurePath("/home/victim"))

    assert decide_stale_root(root, {TMP}, NOW) == Keep(ENTRY, Policy.SWAPPED_PARENT)


def test_a_root_with_a_dot_dot_in_its_parent_stays() -> None:
    root = gc_root(TMP / "../home/result", resolved_parent=PurePath("/home"))

    assert decide_stale_root(root, {TMP}, NOW) == Keep(ENTRY, Policy.SWAPPED_PARENT)


def test_a_root_whose_link_is_gone_stays() -> None:
    assert decide_stale_root(gc_root(probe=Absent()), {TMP}, NOW) == Keep(
        ENTRY, Policy.GONE
    )


def test_a_root_replaced_by_a_directory_stays() -> None:
    root = gc_root(probe=stat_of(Kind.DIRECTORY, 3 * DAY_SECONDS))

    assert decide_stale_root(root, {TMP}, NOW) == Keep(ENTRY, Policy.NOT_A_LINK)


def test_an_unreadable_root_stays() -> None:
    assert decide_stale_root(GcRoot(ENTRY, UNKNOWN), {TMP}, NOW) == Keep(ENTRY, UNKNOWN)


def test_a_root_whose_parent_cannot_be_resolved_stays() -> None:
    assert decide_stale_root(gc_root(resolved_parent=UNKNOWN), {TMP}, NOW) == Keep(
        ENTRY, UNKNOWN
    )


def test_the_owner_gets_the_link_itself() -> None:
    assert decide_own_stale_root(gc_root(), {TMP}, NOW, UID) == Remove(LINK_PATH)


def test_another_account_s_link_stays() -> None:
    root = gc_root(probe=stat_of(Kind.SYMLINK, 3 * DAY_SECONDS, UID + 1))

    assert decide_own_stale_root(root, {TMP}, NOW, UID) == Keep(
        LINK_PATH, Policy.OTHER_OWNER
    )


@given(
    names,
    relative_paths,
    ages,
    probes | st.just(stat_of(Kind.SYMLINK, 3 * DAY_SECONDS)),
)
def test_a_parent_that_resolves_elsewhere_is_never_removed(
    name: str, below: PurePath, age: float, probe: Probe
) -> None:
    root = gc_root(
        TMP / below / name,
        probe if isinstance(probe, Stat) else stat_of(Kind.SYMLINK, age),
        resolved_parent=PurePath("/elsewhere") / below,
    )

    assert isinstance(decide_stale_root(root, {TMP}, NOW), Keep)
    assert isinstance(decide_own_stale_root(root, {TMP}, NOW, UID), Keep)


@given(ages, probes)
def test_a_root_is_unregistered_only_when_a_known_link_older_than_two_days(
    age: float, probe: Probe
) -> None:
    link_probe = replace(probe, mtime=NOW - age) if isinstance(probe, Stat) else probe

    decision = decide_stale_root(gc_root(probe=link_probe), {TMP}, NOW)

    is_link = isinstance(probe, Stat) and probe.kind is Kind.SYMLINK
    assert isinstance(decision, Remove) == (is_link and age > 2 * DAY_SECONDS)


@given(names, st.integers(min_value=0, max_value=2000))
def test_a_generation_shaped_name_is_never_unregistered(
    name: str, generation: int
) -> None:
    root = gc_root(TMP / f"{name}-{generation}-link")

    assert isinstance(decide_stale_root(root, {TMP}, NOW), Keep)


@given(st.integers(min_value=0, max_value=2000))
def test_only_the_link_s_owner_may_remove_it(uid: int) -> None:
    root = gc_root(probe=stat_of(Kind.SYMLINK, 3 * DAY_SECONDS, uid))

    decision = decide_own_stale_root(root, {TMP}, NOW, UID)

    assert isinstance(decision, Remove) == (uid == UID)


def render_worktrees(worktrees: list[ListedWorktree]) -> str:
    """As `git worktree list --porcelain -z` prints them."""

    def record(worktree: ListedWorktree) -> str:
        lock = ["locked why"] if worktree.locked else []
        return (
            "\0".join([f"worktree {worktree.path}", "HEAD abc", "detached", *lock])
            + "\0\0"
        )

    return "".join(record(worktree) for worktree in worktrees)


def test_the_listing_reads_paths_and_locks() -> None:
    listing = (
        f"worktree {REPOSITORY}\0HEAD abc\0branch refs/heads/main\0\0"
        f"worktree {WORKTREE}\0HEAD abc\0detached\0locked\0\0"
    )

    assert parse_worktrees(listing) == (
        ListedWorktree(REPOSITORY, locked=False),
        ListedWorktree(WORKTREE, locked=True),
    )


def test_a_branch_named_like_a_lock_does_not_lock() -> None:
    listing = f"worktree {WORKTREE}\0HEAD abc\0branch refs/heads/locked\0\0"

    assert parse_worktrees(listing) == (ListedWorktree(WORKTREE, locked=False),)


def test_an_empty_listing_is_unknown() -> None:
    assert isinstance(parse_worktrees(""), Unknown)


def test_a_listing_with_a_record_it_cannot_read_is_unknown() -> None:
    listing = f"worktree {WORKTREE}\0HEAD abc\0\0nonsense\0\0"

    assert isinstance(parse_worktrees(listing), Unknown)


def test_a_relative_worktree_path_is_unknown() -> None:
    assert isinstance(parse_worktrees("worktree shop\0HEAD abc\0\0"), Unknown)


@given(st.lists(listed_worktrees, min_size=1))
def test_a_listing_reads_back_what_git_wrote(worktrees: list[ListedWorktree]) -> None:
    assert parse_worktrees(render_worktrees(worktrees)) == tuple(worktrees)


@given(st.text())
def test_any_listing_parses_to_absolute_worktrees_or_unknown(listing: str) -> None:
    parsed = parse_worktrees(listing)

    assert isinstance(parsed, Unknown) or all(w.path.is_absolute() for w in parsed)


def test_pgrep_s_listing_excludes_this_process() -> None:
    assert parse_pids("12\n34\n", own_pid=34) == frozenset({12})


def test_no_processes_is_a_known_empty_set() -> None:
    assert parse_pids("", own_pid=1) == frozenset()


def test_a_listing_of_something_else_is_unknown() -> None:
    assert isinstance(parse_pids("12\nerror\n", own_pid=1), Unknown)


@given(st.sets(st.integers(min_value=1, max_value=4_000_000)), st.integers(min_value=1))
def test_every_listed_pid_reads_back_but_our_own(pids: set[int], own_pid: int) -> None:
    listing = "".join(f"{pid}\n" for pid in pids)

    assert parse_pids(listing, own_pid) == frozenset(pids - {own_pid})


def test_a_count_reads_as_its_number() -> None:
    assert parse_count("3\n") == 3


@given(
    st.text().filter(
        lambda text: not (text.strip().isascii() and text.strip().isdecimal())
    )
)
def test_anything_but_a_count_is_unknown(output: str) -> None:
    assert isinstance(parse_count(output), Unknown)


def test_a_directory_outside_any_repository_has_unknown_local_work(
    tmp_path: Path,
) -> None:
    work = read_local_work(tmp_path)

    assert isinstance(work.uncommitted, Unknown)
    assert isinstance(work.unpushed, Unknown)


def test_a_probe_describes_the_entry_not_what_it_points_at(tmp_path: Path) -> None:
    link = tmp_path / "link"
    link.symlink_to(tmp_path)

    probe = read_probe(link)

    assert isinstance(probe, Stat)
    assert probe.kind is Kind.SYMLINK


def test_a_missing_path_probes_absent(tmp_path: Path) -> None:
    assert read_probe(tmp_path / "missing") == Absent()


def test_a_missing_tree_has_no_known_newest_write(tmp_path: Path) -> None:
    assert isinstance(read_newest_write(tmp_path / "missing"), Unknown)


def test_a_gc_root_that_is_not_a_link_has_no_known_result_link(tmp_path: Path) -> None:
    entry = tmp_path / "entry"
    entry.touch()

    assert isinstance(read_result_link(entry), Unknown)


def test_a_swapped_parent_reads_as_resolving_elsewhere(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "result").symlink_to("/nowhere")
    swapped = tmp_path / "swap"
    swapped.symlink_to(outside)
    entry = tmp_path / "entry"
    entry.symlink_to(swapped / "result")

    link = read_result_link(entry)

    assert isinstance(link, ResultLink)
    assert link.resolved_parent == outside.resolve()
    assert decide_stale_root(GcRoot(entry, link), {tmp_path}, NOW) != Remove(entry)
