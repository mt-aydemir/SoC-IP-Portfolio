#!/usr/bin/env python3
"""Stage the Sphinx documentation sources into the build tree.

Per-IP documentation is authored next to the IP it describes, in
``ip/<category>/<ip>/docs``. Sphinx, however, needs a single source tree. This
script assembles one under the build directory:

    <stage>/                 <- copy of docs/source (conf.py, hand-written guides)
    <stage>/ip/index.rst     <- generated catalogue
    <stage>/ip/<cat>/index.rst
    <stage>/ip/<cat>/<ip>/   <- copy of the IP's docs/ directory

Nothing is ever written back into the source tree, so ``docs/`` stays free of
generated content and the repository remains clean after a documentation
build.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

# Human-readable names for the IP category directories. A category that is not
# listed here still works; it simply gets its directory name title-cased.
CATEGORY_TITLES = {
    "arithmetic":  "Arithmetic",
    "memory":      "Memory",
    "bus":         "Bus Interconnect and Protocols",
    "peripherals": "Peripherals",
    "dsp":         "Digital Signal Processing",
    "ml":          "Machine Learning",
    "crypto":      "Cryptography",
    "clocking":    "Clocking",
    "cdc":         "Clock Domain Crossing",
    "soc":         "SoC Infrastructure",
}

CATEGORY_ORDER = [
    "arithmetic", "memory", "bus", "peripherals", "dsp",
    "ml", "crypto", "clocking", "cdc", "soc",
]


def underline(text: str, char: str = "=") -> str:
    return f"{text}\n{char * len(text)}\n"


def category_title(name: str) -> str:
    return CATEGORY_TITLES.get(name, name.replace("_", " ").title())


def category_sort_key(name: str) -> tuple[int, str]:
    """Documented categories keep the catalogue order; the rest go last."""
    try:
        return (CATEGORY_ORDER.index(name), name)
    except ValueError:
        return (len(CATEGORY_ORDER), name)


def copy_tree(src: Path, dst: Path) -> None:
    """Mirror *src* onto *dst*, ignoring caches and editor debris."""
    shutil.copytree(
        src, dst,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns(
            "__pycache__", "*.pyc", "*~", ".DS_Store", "_build"),
    )


def ip_summary(ip_dir: Path) -> str:
    """First non-empty prose line of the IP's docs, used in the catalogue.

    Falls back to an empty string, which renders as a bare toctree entry
    rather than failing the build.
    """
    for candidate in ("index.rst", f"{ip_dir.name}.rst"):
        doc = ip_dir / "docs" / candidate
        if not doc.is_file():
            continue
        skip_prefixes = ("..", "=", "-", "~", "^", "#", ":")
        previous_blank = True
        for raw in doc.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line:
                previous_blank = True
                continue
            if line.startswith(skip_prefixes):
                previous_blank = False
                continue
            # A title is followed by an underline; the summary is the first
            # ordinary paragraph, so require the previous line to be blank.
            if previous_blank and not line.startswith(skip_prefixes):
                return line
            previous_blank = False
    return ""


def discover(ip_root: Path) -> dict[str, list[Path]]:
    """Map category name -> list of IP directories that have documentation."""
    found: dict[str, list[Path]] = {}
    if not ip_root.is_dir():
        return found
    for category in sorted(p for p in ip_root.iterdir() if p.is_dir()):
        ips = [
            ip for ip in sorted(p for p in category.iterdir() if p.is_dir())
            if (ip / "docs").is_dir()
            and (list((ip / "docs").glob("*.rst")) or list((ip / "docs").glob("*.md")))
        ]
        if ips:
            found[category.name] = ips
    return found


def doc_entry_name(ip_dir: Path) -> str:
    """Name of the IP's root document, without the extension."""
    if (ip_dir / "docs" / "index.rst").is_file():
        return "index"
    for path in sorted((ip_dir / "docs").glob("*.rst")):
        return path.stem
    for path in sorted((ip_dir / "docs").glob("*.md")):
        return path.stem
    return "index"


def write_category_index(stage_ip: Path, category: str, ips: list[Path]) -> None:
    lines = [
        f".. _cat-{category}:\n",
        "",
        underline(category_title(category)),
        "",
        f"{len(ips)} IP block{'s' if len(ips) != 1 else ''} in this category.",
        "",
        ".. toctree::",
        "   :maxdepth: 1",
        "",
    ]
    for ip in ips:
        lines.append(f"   {ip.name}/{doc_entry_name(ip)}")
    lines.append("")

    (stage_ip / category / "index.rst").write_text(
        "\n".join(lines), encoding="utf-8")


def write_catalogue(stage_ip: Path, categories: dict[str, list[Path]]) -> None:
    total = sum(len(v) for v in categories.values())
    lines = [
        ".. _ip-catalogue:\n",
        "",
        underline("IP Catalogue"),
        "",
        f"The portfolio currently contains **{total} IP blocks** across "
        f"**{len(categories)} categories**. Every block is vendor independent, "
        "parameterised, linted, simulated and synthesised by the same flow.",
        "",
        ".. list-table::",
        "   :header-rows: 1",
        "   :widths: 30 15 55",
        "",
        "   * - Category",
        "     - Blocks",
        "     - Contents",
    ]
    for category in sorted(categories, key=category_sort_key):
        ips = categories[category]
        names = ", ".join(f":doc:`{ip.name} <{category}/{ip.name}/{doc_entry_name(ip)}>`"
                          for ip in ips)
        lines += [
            f"   * - :ref:`{category_title(category)} <cat-{category}>`",
            f"     - {len(ips)}",
            f"     - {names}",
        ]

    lines += [
        "",
        ".. toctree::",
        "   :maxdepth: 2",
        "   :hidden:",
        "",
    ]
    for category in sorted(categories, key=category_sort_key):
        lines.append(f"   {category}/index")
    lines.append("")

    (stage_ip / "index.rst").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="repository root")
    parser.add_argument("--stage", required=True,
                        help="destination source tree, inside the build directory")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    stage = Path(args.stage).resolve()

    if stage.is_relative_to(root / "docs"):
        sys.stderr.write(
            f"refusing to stage into the source tree: {stage}\n"
            "the staging directory must live under the build directory\n")
        return 1

    docs_source = root / "docs" / "source"
    if not docs_source.is_dir():
        sys.stderr.write(f"missing documentation source tree: {docs_source}\n")
        return 1

    # Start from a clean stage so a removed IP cannot linger in the output.
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    copy_tree(docs_source, stage)

    categories = discover(root / "ip")
    stage_ip = stage / "ip"
    stage_ip.mkdir(parents=True, exist_ok=True)

    for category, ips in categories.items():
        (stage_ip / category).mkdir(parents=True, exist_ok=True)
        for ip in ips:
            copy_tree(ip / "docs", stage_ip / category / ip.name)
        write_category_index(stage_ip, category, ips)

    write_catalogue(stage_ip, categories)

    total = sum(len(v) for v in categories.values())
    print(f"docs staged: {total} IP(s), {len(categories)} category(ies) -> {stage}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
