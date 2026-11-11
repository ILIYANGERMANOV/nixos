#!/usr/bin/env python3
"""Count the lines of a PR body a reader sees before expanding anything.

Prints the number of non-empty lines GitHub shows with every collapsed
`<details>` block reduced to its `<summary>`. A `<details open>` block renders
expanded, so its content counts. Standard library only.

Usage: visible_lines.py <body.md>

Markup inside backticks, a code span or a fenced block, is text, not a tag.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# A backtick run up to the next run of the same length is code: a code span,
# or a whole fenced block, whose fences are runs too. Matched first so the
# tags it holds stay text.
TAG = re.compile(
    "|".join(
        [
            r"(?P<code>(?P<ticks>`+).*?(?<!`)(?P=ticks)(?!`))",
            r"<details(?P<attrs>\s[^>]*)?>",
            r"(?P<close></details>)",
            r"<summary>(?P<summary>.*?)</summary>",
        ]
    ),
    re.IGNORECASE | re.DOTALL,
)
OPEN = re.compile(r"\bopen\b", re.IGNORECASE)


def main(argv: list[str]) -> int:
    match argv:
        case [path]:
            print(count_visible(Path(path).read_text(encoding="utf-8")))
            return 0
        case _:
            print("usage: visible_lines.py <body.md>", file=sys.stderr)
            return 2


def count_visible(body: str) -> int:
    return sum(1 for line in _visible_text(body).splitlines() if line.strip())


def _visible_text(body: str) -> str:
    """The body as rendered collapsed: tags dropped, hidden content dropped,
    each summary on its own line."""
    parts: list[str] = []
    # One flag per enclosing <details>: True when it renders expanded.
    expanded: list[bool] = []
    pos = 0
    for tag in TAG.finditer(body):
        if tag["code"] is not None:
            continue
        if all(expanded):
            parts.append(body[pos : tag.start()])
        pos = tag.end()
        if tag["close"] is not None:
            # A stray </details> closes nothing on GitHub either.
            if expanded:
                del expanded[-1]
        elif tag["summary"] is not None:
            # A summary shows when its own block's parents are all expanded.
            if all(expanded[:-1]):
                parts.append(f"\n{tag['summary']}\n")
        else:
            expanded.append(OPEN.search(tag["attrs"] or "") is not None)
    if all(expanded):
        parts.append(body[pos:])
    return "".join(parts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
