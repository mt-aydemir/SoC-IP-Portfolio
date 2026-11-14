#!/usr/bin/env python3
"""Repository-level test: the delivery scripts the CI publishes with.

``release_notes.py`` must find exactly one version's section, refuse a tag
without one, and leave link references out. ``build_site.py`` must read every
report format of the flow and mark a failing report as failing, since the
published page is only worth something if a red result shows red.

Everything is built in a temporary directory: the source stays clean.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CHANGELOG = """# Changelog

## [Unreleased]

### Added

- Upcoming.

## [1.1.0] - 2026-12-01

### Fixed

- A fix.

## [1.0.0] - 2026-11-20

### Added

- First release.

[1.1.0]: https://example.invalid/compare/v1.0.0...v1.1.0
[1.0.0]: https://example.invalid/releases/tag/v1.0.0
"""

REPORTS = {
    "sim/good.test_good.xml":
        '<testsuites><testsuite><testcase name="a"/><testcase name="b"/></testsuite></testsuites>',
    "sim/bad.test_bad.xml":
        '<testsuites><testsuite><testcase name="a"><failure/></testcase></testsuite></testsuites>',
    "synth/good.json": json.dumps({"status": "pass", "total_cells": 128, "area": 209.4}),
    "sta/good.rpt": "  3.6870   slack (MET)\n  1.2500   slack (MET)\n",
    "sta/bad.rpt": "  -0.5000   slack (VIOLATED)\n",
    "formal/good.log": "summary: successful proof\nDONE (PASS, rc=0)\n",
    "svtb/good.log": "TEST PASSED: tb_good\n",
    "uvm/bad.registered_0.random_test.log": "UVM_ERROR :    2\nUVM_FATAL :    0\n",
    "lint/good.log": "%Warning-UNUSED: x\n",
}

EXPECTED = {  # report -> (passed, text that must appear in its cell)
    "sim/good.test_good.xml": (True, "2/2 tests"),
    "sim/bad.test_bad.xml": (False, "0/1 tests"),
    "synth/good.json": (True, "128 cells"),
    "sta/good.rpt": (True, "worst slack 1.25 ns"),
    "sta/bad.rpt": (False, "worst slack -0.5 ns"),
    "formal/good.log": (True, "proved"),
    "svtb/good.log": (True, "passed"),
    "uvm/bad.registered_0.random_test.log": (False, "2 errors"),
    "lint/good.log": (True, "1 warnings"),
}


def run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, *cmd], capture_output=True, text=True)


def check_notes(root: Path, tmp: Path) -> list[str]:
    errors = []
    script = str(root / "scripts" / "release_notes.py")
    log = tmp / "CHANGELOG.md"
    log.write_text(CHANGELOG, encoding="utf-8")
    r = run(script, "v1.0.0", "--changelog", str(log))
    if r.returncode != 0 or r.stdout.strip() != "### Added\n\n- First release.":
        errors.append(f"v1.0.0 notes wrong (rc={r.returncode}): {r.stdout!r} {r.stderr!r}")
    r = run(script, "v1.1.0", "--changelog", str(log))
    if r.returncode != 0 or "A fix." not in r.stdout or "First release" in r.stdout:
        errors.append(f"v1.1.0 notes leak into the next section: {r.stdout!r}")
    for bad_tag in ("v2.0.0", "1.0.0", "v1.0"):
        if run(script, bad_tag, "--changelog", str(log)).returncode == 0:
            errors.append(f"tag {bad_tag} accepted without a matching section")
    real = run(script, "v0.0.0", "--changelog", str(root / "CHANGELOG.md"))
    if real.returncode == 0:
        errors.append("the real CHANGELOG answered for a version it does not have")
    return errors


def check_site(root: Path, tmp: Path) -> list[str]:
    errors = []
    docs, reports, out = tmp / "docs", tmp / "reports", tmp / "site"
    docs.mkdir()
    (docs / "index.html").write_text("<html>docs</html>", encoding="utf-8")
    for rel, text in REPORTS.items():
        path = reports / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    r = run(str(root / "scripts" / "build_site.py"), "--docs", str(docs),
            "--reports", str(reports), "--out", str(out), "--commit", "abc123")
    if r.returncode != 0:
        return [f"build_site failed: {r.stderr}"]
    for name in ("index.html", ".nojekyll", "reports/index.html", "reports/sta/good.rpt"):
        if not (out / name).is_file():
            errors.append(f"site is missing {name}")
    page = (out / "reports" / "index.html").read_text(encoding="utf-8")
    for rel, (ok, text) in EXPECTED.items():
        cell = f'<td class="{"pass" if ok else "fail"}"><a href="{rel}">'
        if cell not in page:
            errors.append(f"{rel}: expected a {'pass' if ok else 'fail'} cell linking it")
        if text not in page:
            errors.append(f"{rel}: summary text {text!r} missing")
    if "6 of 9 reports passed" not in page:
        errors.append("headline count wrong")
    return errors


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", required=True)
    root = Path(os.path.abspath(p.parse_args().root))
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "n").mkdir()
        (tmp / "s").mkdir()
        errors = check_notes(root, tmp / "n") + check_site(root, tmp / "s")
    for e in errors:
        print(f"FAIL: {e}")
    if errors:
        return 1
    print("release tools: notes and site OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
