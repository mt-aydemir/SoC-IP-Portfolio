"""Sphinx configuration for the SoC IP portfolio documentation.

This file is copied into the build tree by ``scripts/generate_ip_docs.py``
together with the hand-written guides and the staged per-IP documentation.
Sphinx therefore always runs against ``build/docs/source``; nothing is
generated inside the repository.
"""
from __future__ import annotations

# -- Project information -----------------------------------------------------

project = "SoC IP Portfolio"
author = "SoC IP Portfolio Contributors"
copyright = "2026, SoC IP Portfolio Contributors"  # noqa: A001 - Sphinx name
release = "0.1.0"
version = "0.1"

# -- General configuration ---------------------------------------------------

extensions = [
    "sphinx.ext.todo",
    "sphinx.ext.githubpages",
    "myst_parser",
]

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

master_doc = "index"
templates_path = ["_templates"]
exclude_patterns = ["_build"]

# The documentation is built with -W, so an unreferenced page is an error.
# That is deliberate: it stops an IP's documentation from silently dropping
# out of the catalogue.
nitpicky = False
todo_include_todos = False

# -- Options for HTML output -------------------------------------------------

html_theme = "sphinx_rtd_theme"
html_static_path = ["_static"]
html_title = f"{project} {release}"
html_short_title = project

html_theme_options = {
    "collapse_navigation": False,
    "navigation_depth": 3,
    "titles_only": False,
}

# -- MyST --------------------------------------------------------------------

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "linkify",
]
myst_heading_anchors = 3
