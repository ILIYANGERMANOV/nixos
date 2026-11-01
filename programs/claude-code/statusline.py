"""Claude Code's status line: the JSON on stdin as one line of coloured text.

`parse` and `render` decide everything and are pure. `main` reads what they depend
on: stdin, the clock, the git branch and the system appearance. Input that cannot
be read prints nothing, so a broken field blanks the line rather than lying.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import cast

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

BOLD = "\033[1m"
RESET = "\033[0m"
BAR_WIDTH = 5
# A bar is as long as its percentage, so one this high is garbage, not a reading.
MAX_PERCENT = 1_000_000
WARNING_PERCENT = 50
CRITICAL_PERCENT = 80
SECONDS_PER_MINUTE = 60
MINUTES_PER_HOUR = 60

# Where the fields live, each with its fallback.
CWD = (("workspace", "current_dir"), ("cwd",))
MODEL = (("model", "display_name"), ("model", "id"))
USED_PERCENT = (("rate_limits", "five_hour", "used_percentage"),)
RESETS_AT = (("rate_limits", "five_hour", "resets_at"),)
CONTEXT_SIZE = (("context_window", "context_window_size"),)
CONTEXT_PERCENT = (("context_window", "used_percentage"),)


@dataclass(frozen=True, slots=True)
class Palette:
    cyan: str
    green: str
    blue: str
    grey: str
    yellow: str
    red: str


# Bright and pastel, for dark terminals.
DARK = Palette(
    cyan="\033[38;5;116m",
    green="\033[38;5;114m",
    blue="\033[38;5;111m",
    grey="\033[38;5;245m",
    yellow="\033[38;5;215m",
    red="\033[38;5;210m",
)
# Dark and saturated, readable on white.
LIGHT = Palette(
    cyan="\033[38;5;30m",
    green="\033[38;5;28m",
    blue="\033[38;5;26m",
    grey="\033[38;5;240m",
    yellow="\033[38;5;166m",
    red="\033[38;5;160m",
)


@dataclass(frozen=True, slots=True)
class RateLimit:
    percent: int
    resets_at: int | None


@dataclass(frozen=True, slots=True)
class ContextWindow:
    size: int
    percent: int


@dataclass(frozen=True, slots=True)
class Status:
    cwd: str
    model: str
    limit: RateLimit | None
    context: ContextWindow | None


@dataclass(frozen=True, slots=True)
class Unreadable:
    pass


def main() -> None:
    match parse(read_input()):
        case Unreadable():
            pass
        case Status() as status:
            line = render(
                status,
                current_branch(status.cwd),
                int(time.time()),
                palette_for("@theme@"),
            )
            _ = sys.stdout.buffer.write(f"{line}\n".encode(errors="replace"))


def parse(raw: str) -> Status | Unreadable:
    try:
        doc = cast("Json", json.loads(raw)) if raw.strip() else None
        return Status(
            cwd=text_at(doc, *CWD),
            model=text_at(doc, *MODEL),
            limit=parse_limit(text_at(doc, *USED_PERCENT), text_at(doc, *RESETS_AT)),
            context=parse_context(
                text_at(doc, *CONTEXT_SIZE), text_at(doc, *CONTEXT_PERCENT)
            ),
        )
    except (ValueError, RecursionError):
        return Unreadable()


def render(status: Status, branch: str, now: int, palette: Palette) -> str:
    return "".join(
        (
            place_segment(status.cwd, branch, palette),
            model_segment(status.model, palette),
            limit_segment(status.limit, now, palette),
            context_segment(status.context, palette),
        )
    )


def text_at(doc: Json, *paths: tuple[str, ...]) -> str:
    """The first path holding something other than null or false, as text.

    A number or a boolean is only ever read through its text, so a string
    spelling a number works the same as the number.
    """
    for path in paths:
        match value_at(doc, path):
            case None | False:
                pass
            case str() as text:
                return clean(text)
            case other:
                return clean(json.dumps(other, ensure_ascii=False))
    return ""


def value_at(doc: Json, path: tuple[str, ...]) -> Json:
    """Null past a missing key. Reading a field of anything else is a ValueError."""
    value = doc
    for key in path:
        match value:
            case None:
                return None
            case dict():
                value = value.get(key)
            case _:
                raise ValueError(f"no field {key}")
    return value


def clean(text: str) -> str:
    """Text fit for a terminal and for argv: no NUL, no lone surrogate."""
    return text.encode(errors="replace").decode().replace("\0", "").rstrip("\n")


def parse_limit(used: str, resets_at: str) -> RateLimit | None:
    return RateLimit(whole_percent(used), parse_reset(resets_at)) if used else None


def parse_context(size: str, used: str) -> ContextWindow | None:
    return ContextWindow(int(size), whole_percent(used)) if size and used else None


def whole_percent(text: str) -> int:
    value = float(text)
    if not abs(value) <= MAX_PERCENT:
        raise ValueError(f"not a percentage: {text}")
    return round(value)


def parse_reset(text: str) -> int | None:
    """A reset time that is not a whole number loses the countdown, not the line."""
    try:
        return int(text)
    except ValueError:
        return None


def place_segment(cwd: str, branch: str, palette: Palette) -> str:
    if not cwd:
        return ""
    place = f"{palette.cyan}{base_name(cwd)}{RESET}"
    return f"{place}  {palette.green}{branch}{RESET}" if branch else place


def base_name(path: str) -> str:
    return path.rstrip("/").rpartition("/")[2] or "/"


def model_segment(model: str, palette: Palette) -> str:
    return f"  {palette.blue}{model}{RESET}" if model else ""


def limit_segment(limit: RateLimit | None, now: int, palette: Palette) -> str:
    match limit:
        case None:
            return ""
        case RateLimit(percent, resets_at):
            color = tone(percent, palette.grey, palette.yellow, palette.red)
            countdown = "" if resets_at is None else time_left(resets_at, now)
            return f"  {color}{bar(percent)} {percent}%{countdown}{RESET}"


def context_segment(context: ContextWindow | None, palette: Palette) -> str:
    match context:
        case None:
            return ""
        case ContextWindow(size, percent):
            lead = tone(
                percent,
                palette.green,
                f"{BOLD}{palette.yellow}~ ",
                f"{BOLD}{palette.red}⚠ ",
            )
            used_k = truncated(truncated(size * percent, 100), 1000)
            return f"  {lead}{used_k}k / {truncated(size, 1000)}k ({percent}%){RESET}"


def tone[T](percent: int, calm: T, warning: T, critical: T) -> T:
    if percent >= CRITICAL_PERCENT:
        return critical
    return warning if percent >= WARNING_PERCENT else calm


def bar(percent: int) -> str:
    filled = truncated(percent * BAR_WIDTH, 100)
    return "▓" * filled + "░" * (BAR_WIDTH - filled)


def time_left(resets_at: int, now: int) -> str:
    minutes = (resets_at - now) // SECONDS_PER_MINUTE
    if minutes <= 0:
        return ""
    if minutes < MINUTES_PER_HOUR:
        return f" (reset {minutes}m)"
    hours, rest = divmod(minutes, MINUTES_PER_HOUR)
    return f" (reset {hours}h{rest}m)"


def truncated(numerator: int, denominator: int) -> int:
    """Division towards zero, for a positive denominator: `//` floors a negative."""
    quotient = abs(numerator) // denominator
    return -quotient if numerator < 0 else quotient


def read_input() -> str:
    """Stdin as text, nothing when it is closed."""
    try:
        with open(0, "rb", closefd=False) as stdin:
            return stdin.read().decode(errors="replace")
    except OSError:
        return ""


def current_branch(cwd: str) -> str:
    """The branch at cwd, else the short commit, else nothing outside a repository."""
    if not cwd:
        return ""
    return git(cwd, "symbolic-ref", "--short", "HEAD") or git(
        cwd, "rev-parse", "--short", "HEAD"
    )


def git(cwd: str, *args: str) -> str:
    try:
        done = subprocess.run(
            ["@git@", "-C", cwd, *args],
            capture_output=True,
            check=False,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
    except OSError:  # An argument past the kernel's limit.
        return ""
    return done.stdout.decode(errors="replace").strip() if done.returncode == 0 else ""


def palette_for(theme: str) -> Palette:
    match theme:
        case "dark":
            return DARK
        case "light":
            return LIGHT
        case _:
            return DARK if system_is_dark() else LIGHT


def system_is_dark() -> bool:
    """Asks macOS where it can, else GNOME. Their tools are the system's, not pinned."""
    if shutil.which("defaults"):
        return "Dark" in stdout_of("defaults", "read", "-g", "AppleInterfaceStyle")
    if shutil.which("gsettings"):
        schema = "org.gnome.desktop.interface"
        return "dark" in stdout_of("gsettings", "get", schema, "color-scheme")
    return False


def stdout_of(*argv: str) -> str:
    done = subprocess.run(argv, capture_output=True, check=False)
    return done.stdout.decode(errors="replace")


if __name__ == "__main__":
    main()
