#!/usr/bin/env python3
"""Documentation reference gate.

Fails on:
  (a) stale path/command tokens in markdown docs (flat uppercase doc names,
      old directory layouts, old launcher commands);
  (b) every local ``](...)`` markdown link whose target is a file path that
      does not exist on disk (anchors are ignored);
  (c) every ``scripts/...`` and ``src/...`` path mentioned in markdown docs
      that does not exist on disk.

Only markdown files are scanned: source code legitimately mentions names
like ``_core_impl`` or ``bootstrap/native_compile`` in comments/docstrings,
so this gate must not scan ``src/`` or ``tests/``.

Intentional historical notes that must keep a stale-looking token can be
exempted via ALLOWLIST below as (relative-path, regex) pairs. Keep that
list empty unless there is a genuine reason.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (a) Stale tokens: old doc names, old layouts, old launchers.
STALE_PATTERNS = [
    # Flat uppercase doc names from before docs/ gained subdirectories.
    r"00-ARCHITECTURE",
    r"01-CORE-LANGUAGE",
    r"02-GRAMMAR",
    r"03-CORE-SEMANTICS",
    r"04-CONFORMANCE",
    r"05-HOST-MODULE",
    r"06-LIBRARIES",
    r"07-IMPLEMENTATION",
    r"08-TOOLCHAIN",
    r"09-DESIGN-RATIONALE",
    r"10-OPEN-QUESTIONS",
    r"11-CODE-ANALYSIS",
    r"12-LANGUAGE-TOUR",
    r"13-ROADMAP",
    r"14-SELF-HOSTING",
    r"15-PORTABLE-LIBRARY",
    # Old source layouts.
    r"native_vm\.c",
    r"lib/core",
    r"lib/portable",
    r"lib/hosted",
    r"run_lang\.py",
    r"conformance/core_conformance",
    r"(?<![\w.])conformance/",
    r"bootstrap/native_compile",
    r"(?<![\w.])bootstrap/",
    r"(?<![\w.])runtime/",
    r"(?<![\w.])notes/",
    r"_core_impl",
    r"_sdk_cli_impl",
    # Old top-level launchers (they live under scripts/ now).
    r"(?<![\w/])\./(?:lc|lr|lsyntax|lcheck|lace|l-lsp|json-lsp|ini-lsp|build\.sh|test\.sh)(?![\w-])",
]
STALE_RE = re.compile("|".join(STALE_PATTERNS))

# (file relative to repo root, regex exempted on matching lines)
ALLOWLIST: list[tuple[str, str]] = []

LINK_RE = re.compile(r"\]\(([^)\s]+)\)")
# Links inside code spans/fences are literal text, not links (e.g. `f[T](args)`).
CODE_SPAN_RE = re.compile(r"```.*?```|`[^`\n]*`", re.DOTALL)
PATH_MENTION_RE = re.compile(r"(?:scripts|src)/[A-Za-z0-9_.\-/]+")
TRAILING_PUNCT = ".,;:!?)\"'"


def markdown_files() -> list[str]:
    found = []
    for base in ("README.md", "AGENTS.md", "CONTRIBUTING.md", "docs", ".github"):
        path = os.path.join(ROOT, base)
        if os.path.isfile(path) and path.endswith(".md"):
            found.append(path)
        elif os.path.isdir(path):
            for dirpath, _dirs, files in os.walk(path):
                for name in sorted(files):
                    if name.endswith(".md"):
                        found.append(os.path.join(dirpath, name))
    return sorted(found)


def exempted(relpath: str, line: str) -> bool:
    return any(
        relpath == allow_file and re.search(allow_pat, line)
        for allow_file, allow_pat in ALLOWLIST
    )


def check_stale_tokens(path: str, relpath: str, errors: list[str]) -> None:
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            match = STALE_RE.search(line)
            if match and not exempted(relpath, line):
                errors.append(
                    f"{relpath}:{lineno}: stale token {match.group(0)!r}: {line.strip()}"
                )


def is_external(target: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target)) or target.startswith("#")


def check_links(path: str, relpath: str, errors: list[str]) -> None:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    text = CODE_SPAN_RE.sub("", text)
    for match in LINK_RE.finditer(text):
        target = match.group(1).split("#", 1)[0].strip()
        if not target or is_external(target):
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if not os.path.exists(resolved):
            errors.append(
                f"{relpath}: broken link target {target!r} "
                f"(resolves to {os.path.relpath(resolved, ROOT)})"
            )


def check_path_mentions(path: str, relpath: str, errors: list[str]) -> None:
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            for match in PATH_MENTION_RE.finditer(line):
                mention = match.group(0).rstrip(TRAILING_PUNCT).rstrip("/")
                if not mention:
                    continue
                if not os.path.exists(os.path.join(ROOT, mention)):
                    errors.append(
                        f"{relpath}:{lineno}: missing path {mention!r}: {line.strip()}"
                    )


def main() -> int:
    errors: list[str] = []
    files = markdown_files()
    if not files:
        print("check_docs: no markdown files found", file=sys.stderr)
        return 1
    for path in files:
        relpath = os.path.relpath(path, ROOT)
        check_stale_tokens(path, relpath, errors)
        check_links(path, relpath, errors)
        check_path_mentions(path, relpath, errors)
    if errors:
        print(f"check_docs: {len(errors)} problem(s) in {len(files)} file(s):")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"check_docs: PASS ({len(files)} markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
