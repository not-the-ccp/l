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
    r"(?<![\w/])\./(?:lc|lr|lsyntax|lcheck|lace|l-lsp|json-lsp|ini-lsp|build\.sh|"
    r"test\.sh)(?![\w-])",
]
STALE_RE = re.compile("|".join(STALE_PATTERNS))

# (file relative to repo root, regex exempted on matching lines)
ALLOWLIST: list[tuple[str, str]] = []

LINK_RE = re.compile(r"\]\(([^)\s]+)\)")
# Links inside code spans/fences are literal text, not links (e.g. `f[T](args)`).
CODE_SPAN_RE = re.compile(r"```.*?```|`[^`\n]*`", re.DOTALL)
PATH_MENTION_RE = re.compile(r"(?:scripts|src)/[A-Za-z0-9_.\-/]+")
TRAILING_PUNCT = ".,;:!?)\"'"

# R1/R2 disputed trio: retired denials that must never come back, plus the
# grammar productions that pin the resolutions. STAGE S3 regression gate.
DISPUTED_STALE_RES = [
    # The retired "no escape hatch" denial (replaced by f[T](args)).
    re.compile(r"no explicit generic-call type-argument syntax"),
    # The retired "string literal is mutable" claim (inferred const []u8).
    re.compile(r"string literal is a mutable byte array"),
]
GRAMMAR_FILE = os.path.join(ROOT, "docs", "language", "02-grammar.ebnf")
# (description, regex that must match the grammar text)
DISPUTED_GRAMMAR_RES = [
    ("generic-call hatch production", re.compile(r"generic_call_suffix\s*="),),
    (
        "tag-only pattern production (payloads optional)",
        re.compile(r"pattern\s*=.*qname,\s*\[", re.DOTALL),
    ),
    (
        "module-const annotation production",
        re.compile(r"const_decl\s*=\s*\"const\",\s*ident,\s*\":\",\s*type"),
    ),
]


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


def check_disputed_trio(files: list[str], errors: list[str]) -> None:
    """R1/R2 regression gate: retired denials stay dead, trio productions stay."""
    for path in files:
        relpath = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as handle:
            for lineno, line in enumerate(handle, 1):
                for stale_re in DISPUTED_STALE_RES:
                    match = stale_re.search(line)
                    if match:
                        errors.append(
                            f"{relpath}:{lineno}: regressed dispute denial "
                            f"{match.group(0)!r}: {line.strip()}"
                        )
    try:
        with open(GRAMMAR_FILE, encoding="utf-8") as handle:
            grammar = handle.read()
    except OSError:
        errors.append("disputed trio: grammar file missing: " + GRAMMAR_FILE)
        return
    for desc, gram_re in DISPUTED_GRAMMAR_RES:
        if not gram_re.search(grammar):
            errors.append(f"disputed trio: grammar lost {desc}")


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
    check_disputed_trio(files, errors)
    if errors:
        print(f"check_docs: {len(errors)} problem(s) in {len(files)} file(s):")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"check_docs: PASS ({len(files)} markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
