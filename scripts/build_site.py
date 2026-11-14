#!/usr/bin/env python3
"""Assemble the GitHub Pages site from one CI run.

The site is the Sphinx HTML at the root and the flow's reports under
``reports/``, with ``reports/index.html`` summarising them: one row per IP
and one column per stage, each cell linking to the report it was read from.

Nothing is recomputed here. Every figure comes from a file the regression
wrote, so the page shows what the run found, including failures.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

STAGES = ("lint", "sim", "svtb", "formal", "uvm", "synth", "sta")
SLACK = re.compile(r"^\s*(-?\d+(?:\.\d+)?)\s+slack\s+\((MET|VIOLATED)\)", re.M)


def ip_of(report: Path) -> str:
    """The IP a report belongs to: the file name up to the first dot."""
    return report.name.split(".", 1)[0]


def read_sim(path: Path) -> tuple[bool, str]:
    cases = failed = 0
    for case in ET.parse(path).getroot().iter("testcase"):
        cases += 1
        if case.find("failure") is not None or case.find("error") is not None:
            failed += 1
    return failed == 0 and cases > 0, f"{cases - failed}/{cases} tests"


def read_synth(path: Path) -> tuple[bool, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    ok = data.get("status") == "pass"
    if "total_cells" in data:
        return ok, f"{data['total_cells']} cells, area {data.get('area', '?')}"
    return ok, str(data.get("status", "?"))


def read_sta(path: Path) -> tuple[bool, str]:
    found = SLACK.findall(path.read_text(encoding="utf-8", errors="replace"))
    if not found:
        return False, "no timing path"
    worst = min(float(v) for v, _ in found)
    return all(s == "MET" for _, s in found), f"worst slack {worst:g} ns"


def read_log(path: Path, stage: str) -> tuple[bool, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if stage == "formal":
        return "DONE (PASS" in text, "proved" if "DONE (PASS" in text else "not proved"
    if stage == "svtb":
        ok = "TEST PASSED" in text and "TEST FAILED" not in text
        return ok, "passed" if ok else "failed"
    if stage == "uvm":
        # A UVM_FATAL still exits 0, so the report server's counts decide.
        counts = re.findall(r"UVM_(?:ERROR|FATAL)\s*:\s*(\d+)", text)
        if not counts:
            return True, "built" if path.name.endswith(".build.log") else "log"
        bad = sum(int(n) for n in counts)
        return bad == 0, "no errors" if bad == 0 else f"{bad} errors"
    # Lint runs with -Wno-fatal: a warning is reported, it does not fail.
    warnings = len(re.findall(r"^%Warning", text, re.M))
    errors = len(re.findall(r"^%Error", text, re.M))
    return errors == 0, f"{warnings} warnings" if errors == 0 else f"{errors} errors"


def read(stage: str, path: Path) -> tuple[bool, str]:
    try:
        if stage == "sim" and path.suffix == ".xml":
            return read_sim(path)
        if stage == "synth" and path.suffix == ".json":
            return read_synth(path)
        if stage == "sta" and path.suffix == ".rpt":
            return read_sta(path)
        return read_log(path, stage)
    except (OSError, ValueError, ET.ParseError) as exc:
        return False, f"unreadable: {exc.__class__.__name__}"


def summarise(reports: Path) -> dict[str, dict[str, list[tuple[str, bool, str]]]]:
    """IP -> stage -> [(relative link, passed, note)]."""
    table: dict[str, dict[str, list[tuple[str, bool, str]]]] = {}
    for stage in STAGES:
        folder = reports / stage
        if not folder.is_dir():
            continue
        for path in sorted(folder.iterdir()):
            if not path.is_file():
                continue
            ok, note = read(stage, path)
            table.setdefault(ip_of(path), {}).setdefault(stage, []).append(
                (f"{stage}/{path.name}", ok, note))
    return table


def render(table, commit: str, run_url: str) -> str:
    stages = [s for s in STAGES if any(s in row for row in table.values())]
    passed = sum(ok for row in table.values() for runs in row.values() for _, ok, _ in runs)
    total = sum(len(runs) for row in table.values() for runs in row.values())
    head = "".join(f"<th>{s}</th>" for s in stages)
    rows = []
    for ip in sorted(table):
        cells = []
        for stage in stages:
            runs = table[ip].get(stage, [])
            if not runs:
                cells.append('<td class="none">-</td>')
                continue
            ok = all(r[1] for r in runs)
            links = "<br>".join(
                f'<a href="{html.escape(link)}">{html.escape(note)}</a>'
                for link, _, note in runs)
            cells.append(f'<td class="{"pass" if ok else "fail"}">{links}</td>')
        rows.append(f"<tr><th>{html.escape(ip)}</th>{''.join(cells)}</tr>")
    run = (f' from <a href="{html.escape(run_url)}">this CI run</a>' if run_url else "")
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SoC IP Portfolio - flow reports</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 2rem; color: #222; }}
table {{ border-collapse: collapse; font-size: 0.85rem; }}
th, td {{ border: 1px solid #ccc; padding: 0.3rem 0.5rem; text-align: left; vertical-align: top; }}
thead th {{ background: #f2f2f2; position: sticky; top: 0; }}
td.pass {{ background: #e8f5e9; }} td.fail {{ background: #ffebee; }}
td.none {{ color: #999; text-align: center; }}
a {{ color: inherit; }}
</style></head><body>
<h1>Flow reports</h1>
<p>Commit <code>{html.escape(commit[:12] or "unknown")}</code>{run}.
{passed} of {total} reports passed. <a href="../index.html">Documentation</a></p>
<table><thead><tr><th>IP</th>{head}</tr></thead><tbody>
{chr(10).join(rows)}
</tbody></table></body></html>
"""


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--docs", required=True, help="Sphinx HTML directory")
    p.add_argument("--reports", required=True, help="build/reports directory")
    p.add_argument("--out", required=True, help="site directory to create")
    p.add_argument("--commit", default=os.environ.get("GITHUB_SHA", ""))
    p.add_argument("--run-url", default="")
    args = p.parse_args()
    docs, reports, out = (Path(os.path.abspath(x)) for x in (args.docs, args.reports, args.out))
    if not (docs / "index.html").is_file():
        print(f"error: no index.html in {docs}", file=sys.stderr)
        return 1
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(docs, out)
    (out / ".nojekyll").write_text("", encoding="utf-8")
    if reports.is_dir():
        shutil.copytree(reports, out / "reports")
    table = summarise(out / "reports") if (out / "reports").is_dir() else {}
    (out / "reports").mkdir(exist_ok=True)
    (out / "reports" / "index.html").write_text(
        render(table, args.commit, args.run_url), encoding="utf-8")
    print(f"site: {out} ({len(table)} IPs with reports)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
