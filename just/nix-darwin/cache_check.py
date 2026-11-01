"""Refuses a build plan that would compile something on the expensive-builds denylist.

Arguments: the label to print, the installable to plan, the denylist file.
Exits 0 on a clean plan, 1 on a denied or an unusable one. A plan nobody can read
never passes. See docs/adr/0004-darwin-tracks-the-darwin-channel.md.
"""

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# What nix prints, one section per kind. Headers stay loose after the kind: the
# fetch one reads "will be fetched (3.3 GiB download...):".
SECTION = re.compile(
    r"^((?:this|these) .*will be (built|fetched)\b.*)\n?((?:[ \t].*\n?)*)",
    re.MULTILINE,
)
ENTRY = re.compile(r"^[ \t]+\S*/[a-z0-9]{32}-(\S+)[ \t]*$", re.MULTILINE)

IGNORED_LINE = re.compile(r"\s*(#.*)?")
# `re` reads this as a set of characters, so it would quietly match nothing.
POSIX_CLASS = re.compile(r"\[:\w+:\]")


@dataclass(frozen=True)
class Denylist:
    """At least one pattern, each one compiled."""

    patterns: tuple[re.Pattern[str], ...]


@dataclass(frozen=True)
class Clean:
    pass


@dataclass(frozen=True)
class Denied:
    names: tuple[str, ...]


@dataclass(frozen=True)
class Unusable:
    reason: str


type Verdict = Clean | Denied | Unusable


@dataclass(frozen=True)
class Section:
    header: str
    kind: str
    entries: str


def main() -> int:
    label, installable, denylist_path = sys.argv[1:]
    denylist = Path(denylist_path).read_text(encoding="utf-8")

    match check(installable, denylist):
        case Clean():
            print(f"{label}: nothing on the denylist would be built.")
            return 0
        case Denied(names):
            print(rejection(label, names), file=sys.stderr)
            return 1
        case Unusable(reason):
            print(f"{label}: cannot vouch for this plan - {reason}", file=sys.stderr)
            return 1


def check(installable: str, denylist_text: str) -> Verdict:
    match parse_denylist(denylist_text):
        case Unusable() as unusable:
            return unusable
        case Denylist() as denylist:
            exit_code, plan = dry_run(installable)
            if exit_code != 0:
                return Unusable(f"nix exited {exit_code}:\n{plan}")
            for section in sections_of(plan):
                print(section.header)
            return judge(plan, denylist)


def dry_run(installable: str) -> tuple[int, str]:
    """Nix prints the plan to stderr. A closure it already has prints no plan at all."""
    process = subprocess.run(
        ["nix", "build", "--dry-run", installable],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return process.returncode, process.stdout


def parse_denylist(text: str) -> Denylist | Unusable:
    patterns = [line for line in text.splitlines() if not IGNORED_LINE.fullmatch(line)]
    if not patterns:
        return Unusable("the denylist has no patterns")

    posix = [pattern for pattern in patterns if POSIX_CLASS.search(pattern)]
    if posix:
        return Unusable(f"POSIX classes do not work in the denylist: {posix[0]}")

    try:
        return Denylist(tuple(re.compile(pattern) for pattern in patterns))
    except re.error as error:
        return Unusable(f"bad denylist pattern {error.pattern!r}: {error}")


def judge(plan: str, denylist: Denylist) -> Verdict:
    """A cold store makes "will be built" mean "substitutable nowhere", the cache misses."""
    match built_names(plan):
        case Unusable() as unusable:
            return unusable
        case names:
            denied = tuple(
                name
                for name in names
                if any(pattern.search(name) for pattern in denylist.patterns)
            )
            return Denied(denied) if denied else Clean()


def built_names(plan: str) -> tuple[str, ...] | Unusable:
    """Derivation names, the store prefix gone: denylist patterns anchor on the name.

    Silence is the risk here: nix may reword what it prints, and a name nobody
    extracted reads as clean. So what looks like a plan but does not parse is refused.
    """
    sections = sections_of(plan)
    for section in sections:
        if (
            not 0
            < len(entry_names(section.entries))
            == len(section.entries.splitlines())
        ):
            return Unusable(
                f"a section that is not a list of store paths: {section.header}"
            )

    stray = entry_names(SECTION.sub("", plan))
    if stray:
        return Unusable(f"a store path outside any section: {stray[0]}")

    return tuple(
        name
        for section in sections
        if section.kind == "built"
        for name in entry_names(section.entries)
    )


def sections_of(plan: str) -> list[Section]:
    return [Section(match[1], match[2], match[3]) for match in SECTION.finditer(plan)]


def entry_names(entries: str) -> list[str]:
    return [match[1] for match in ENTRY.finditer(entries)]


def rejection(label: str, names: tuple[str, ...]) -> str:
    offenders = "\n".join(f"  {name}" for name in names)
    return f"""
{label}: these are on the denylist and would be built locally:
{offenders}

That is hours of rebuild, not minutes. Do not merge this bump - wait for a
nixpkgs rev whose closure for this host is in the cache, or add a substituter
that has it. See docs/adr/0004-darwin-tracks-the-darwin-channel.md."""


if __name__ == "__main__":
    sys.exit(main())
