#!/usr/bin/env python3
"""Repository-level test: IP timing constraints use portable commands only.

Every ``scripts/*.sdc`` under ``ip/`` is a fragment an integrator sources from
their own project, which may be OpenSTA, a Synopsys tool or Vivado. Commands
that exist in only one of them make the fragment fail on the others, and
fail late: a Tcl body inside an ``if`` is not even parsed until it runs.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# Synopsys collection commands with no OpenSTA or Vivado equivalent of the
# same name. Object lists are counted with llength and filtered by building
# them directly (all_inputs -no_clocks, get_ports patterns).
NON_PORTABLE = re.compile(
    r"\b(sizeof_collection|remove_from_collection|add_to_collection|"
    r"foreach_in_collection|filter_collection|index_collection|"
    r"copy_collection|get_attribute)\b")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", required=True)
    root = Path(os.path.abspath(p.parse_args().root))

    problems: list[str] = []
    for sdc in sorted((root / "ip").glob("*/*/scripts/*.sdc")):
        rel = sdc.relative_to(root).as_posix()
        for n, line in enumerate(sdc.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("#", 1)[0]
            # A braced alternative on a line of its own is one of the
            # spellings a socip_* compatibility procedure tries under catch,
            # the only place a tool-specific command is allowed.
            if code.strip().startswith("{"):
                continue
            m = NON_PORTABLE.search(code)
            if m:
                problems.append(f"{rel}:{n}: non-portable command '{m.group(1)}'")

    for p_ in problems:
        print(p_)
    if problems:
        print(f"FAIL: {len(problems)} problem(s)")
        return 1
    print("PASS: SDC fragments are portable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
