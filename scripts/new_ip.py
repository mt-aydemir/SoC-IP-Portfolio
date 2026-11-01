#!/usr/bin/env python3
"""Generate a new, fully conforming IP directory from the portfolio template.

The generated block is a working IP, not an empty skeleton: it lints,
simulates under both testbenches, synthesises, times and documents cleanly
from the moment it is created. That is deliberate — the first commit of a new
block should already pass the regression, so the author is only ever changing
working code.

    python scripts/new_ip.py --category memory --name cache_line_buffer

What it does:

* copies ``templates/ip_template`` to ``ip/<category>/<name>``;
* renames every file and every occurrence of the template identifier;
* fills in the category name and the current date;
* registers the block in ``ip/<category>/CMakeLists.txt``, creating that file
  and the category directory if this is the first block in the family.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import re
import shutil
import sys
from pathlib import Path

TEMPLATE_TOKEN = "template_ip"
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")

# Files copied verbatim: substituting inside them would corrupt the licence.
VERBATIM = {"LICENSE"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--category", required=True,
                   help="IP family, e.g. memory, arithmetic, peripherals")
    p.add_argument("--name", required=True,
                   help="IP name in lower_snake_case, e.g. cache_line_buffer")
    p.add_argument("--root", default=None,
                   help="repository root (default: the parent of this script)")
    p.add_argument("--force", action="store_true",
                   help="overwrite an existing IP directory")
    return p.parse_args()


def substitute(text: str, name: str, category: str) -> str:
    """Replace the template identifiers with the new block's own."""
    text = text.replace(TEMPLATE_TOKEN, name)
    text = text.replace(TEMPLATE_TOKEN.upper(), name.upper())
    text = text.replace("<category>", category)
    text = text.replace("2026-01-01", _dt.date.today().isoformat())
    return text


def copy_ip(template: Path, dest: Path, name: str, category: str) -> list[Path]:
    """Copy the template tree, renaming files and rewriting their contents."""
    created: list[Path] = []
    for src in sorted(template.rglob("*")):
        rel = src.relative_to(template)
        target = dest / Path(*[part.replace(TEMPLATE_TOKEN, name)
                               for part in rel.parts])
        if src.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        if src.name in VERBATIM:
            shutil.copy2(src, target)
        else:
            target.write_text(
                substitute(src.read_text(encoding="utf-8"), name, category),
                encoding="utf-8")
        created.append(target)
    return created


def register(category_dir: Path, category: str, name: str) -> str:
    """Add the block to the category's CMakeLists.txt, in sorted order."""
    cmake = category_dir / "CMakeLists.txt"

    if not cmake.is_file():
        cmake.write_text(
            f"#{'=' * 76}\n"
            f"# ip/{category}\n"
            f"#\n"
            f"# Order is significant: a block may only DEPENDS on a block\n"
            f"# registered before it.\n"
            f"#{'=' * 76}\n"
            f"add_ip_category({category}\n"
            f"  {name}\n"
            f")\n",
            encoding="utf-8")
        return f"created {cmake}"

    text = cmake.read_text(encoding="utf-8")
    if re.search(rf"^\s+{re.escape(name)}\s*$", text, re.MULTILINE):
        return f"already registered in {cmake}"

    # Append just before the closing parenthesis of add_ip_category().
    updated, count = re.subn(r"\n\)\s*$", f"\n  {name}\n)\n", text)
    if count != 1:
        return (f"could not update {cmake} automatically; "
                f"add '{name}' to the add_ip_category() list by hand")
    cmake.write_text(updated, encoding="utf-8")
    return f"registered in {cmake}"


def main() -> int:
    args = parse_args()

    root = Path(args.root).resolve() if args.root \
        else Path(__file__).resolve().parent.parent
    template = root / "templates" / "ip_template"
    if not template.is_dir():
        sys.stderr.write(f"template not found: {template}\n")
        return 1

    if not NAME_RE.match(args.name):
        sys.stderr.write(
            f"invalid IP name '{args.name}': use lower_snake_case starting "
            "with a letter\n")
        return 1
    if not NAME_RE.match(args.category):
        sys.stderr.write(f"invalid category '{args.category}'\n")
        return 1

    category_dir = root / "ip" / args.category
    dest = category_dir / args.name

    if dest.exists():
        if not args.force:
            sys.stderr.write(
                f"{dest} already exists; pass --force to overwrite\n")
            return 1
        shutil.rmtree(dest)

    category_dir.mkdir(parents=True, exist_ok=True)
    created = copy_ip(template, dest, args.name, args.category)

    # Every IP carries its own copy of the licence.
    licence = root / "LICENSE"
    if licence.is_file():
        shutil.copy2(licence, dest / "LICENSE")

    note = register(category_dir, args.category, args.name)

    print(f"created ip/{args.category}/{args.name} ({len(created)} files)")
    print(f"  {note}")
    print()
    print("Next steps:")
    print(f"  1. implement  ip/{args.category}/{args.name}/rtl/{args.name}.sv")
    print(f"  2. extend     ip/{args.category}/{args.name}/cocotb/test_{args.name}.py")
    print(f"  3. document   ip/{args.category}/{args.name}/docs/index.rst")
    print( "  4. verify     cmake -S . -B build -G Ninja && "
          f"ctest --test-dir build -R '{args.name}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
