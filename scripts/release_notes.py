#!/usr/bin/env python3
"""Print the CHANGELOG section of one release.

The release workflow publishes a tag ``vX.Y.Z`` with the notes of
``## [X.Y.Z]`` from the root ``CHANGELOG.md``. A tag with no such section is
an error, so a release can never go out with empty or stale notes: move the
``[Unreleased]`` entries under the new version before tagging.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

TAG = re.compile(r"^v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$")


def section(changelog: str, version: str) -> str | None:
    heading = re.compile(r"^## \[" + re.escape(version) + r"\][^\n]*\n", re.M)
    m = heading.search(changelog)
    if m is None:
        return None
    nxt = re.compile(r"^## \[", re.M).search(changelog, m.end())
    end = nxt.start() if nxt else len(changelog)
    # Link references at the bottom of the file are not part of the notes.
    body = re.split(r"^\[[^\]]+\]:\s", changelog[m.end():end], maxsplit=1, flags=re.M)[0]
    return body.strip()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("tag", help="release tag, e.g. v1.0.0")
    p.add_argument("--changelog", default="CHANGELOG.md")
    args = p.parse_args()
    m = TAG.match(args.tag)
    if m is None:
        print(f"error: tag {args.tag!r} is not vMAJOR.MINOR.PATCH", file=sys.stderr)
        return 1
    text = Path(os.path.abspath(args.changelog)).read_text(encoding="utf-8")
    notes = section(text, m.group(1))
    if not notes:
        print(f"error: CHANGELOG has no non-empty section ## [{m.group(1)}]",
              file=sys.stderr)
        return 1
    print(notes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
