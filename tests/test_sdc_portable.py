#!/usr/bin/env python3
"""Repository-level test: IP timing constraints use portable commands only.

Every ``scripts/*.sdc`` under ``ip/`` is a fragment an integrator sources from
their own project, which may be OpenSTA, a Synopsys tool or Vivado. Commands
that exist in only one of them make the fragment fail on the others, and
fail late: a Tcl body inside an ``if`` is not even parsed until it runs.

The fragments listed in LEGACY predate the rule and are still to be
converted. The list may only shrink: a listed file that has become clean
fails the test until it is removed from the list.
"""
from __future__ import annotations

import argparse
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

LEGACY = {
    "ip/cdc/handshake/scripts/cdc_handshake.sdc",
    "ip/cdc/pulse_sync/scripts/cdc_pulse_sync.sdc",
    "ip/cdc/reset_sync/scripts/cdc_reset_sync.sdc",
    "ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc",
    "ip/clocking/clk_divider/scripts/clk_divider.sdc",
    "ip/clocking/clk_gate/scripts/clk_gate.sdc",
    "ip/clocking/clk_mux/scripts/clk_mux.sdc",
    "ip/clocking/reset_controller/scripts/reset_controller.sdc",
    "ip/memory/bram_ctrl/scripts/bram_ctrl.sdc",
    "ip/memory/fifo_async/scripts/fifo_async.sdc",
    "ip/memory/fifo_sync/scripts/fifo_sync.sdc",
    "ip/memory/register_file/scripts/register_file.sdc",
}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", required=True)
    root = Path(p.parse_args().root).resolve()

    problems: list[str] = []
    for sdc in sorted((root / "ip").glob("*/*/scripts/*.sdc")):
        rel = sdc.relative_to(root).as_posix()
        hits = []
        for n, line in enumerate(sdc.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("#", 1)[0]
            m = NON_PORTABLE.search(code)
            if m:
                hits.append(f"{rel}:{n}: non-portable command '{m.group(1)}'")
        if rel in LEGACY:
            if not hits:
                problems.append(f"{rel}: now portable; remove it from LEGACY")
        else:
            problems.extend(hits)

    for p_ in problems:
        print(p_)
    if problems:
        print(f"FAIL: {len(problems)} problem(s)")
        return 1
    print("PASS: SDC fragments are portable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
