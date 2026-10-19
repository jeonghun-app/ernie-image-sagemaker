# Copyright (c) 2026 ernie-image-sagemaker contributors
# SPDX-License-Identifier: Apache-2.0
"""Check that relative links and #anchors in the Markdown docs point to files and headings that exist.

usage: python3 tests/check_docs.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def slug(heading):
    """GitHub-style anchor of a heading."""
    s = heading.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def anchors(path):
    text = re.sub(r"```.*?```", "", path.read_text(encoding="utf-8"), flags=re.S)
    return {slug(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+)$", text, re.M)}


errors = []
for md in sorted(ROOT.rglob("*.md")):
    if ".git" in md.parts:
        continue
    text = re.sub(r"```.*?```", "", md.read_text(encoding="utf-8"), flags=re.S)
    for target in LINK.findall(text):
        if re.match(r"^[a-z]+:", target):
            continue
        file_part, _, anchor = target.partition("#")
        dest = (md.parent / file_part).resolve() if file_part else md
        if not dest.exists():
            errors.append(f"{md.relative_to(ROOT)}: missing file {target}")
        elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
            errors.append(f"{md.relative_to(ROOT)}: missing anchor {target}")

print("\n".join(errors) if errors else "docs: all relative links resolve")
sys.exit(1 if errors else 0)
