#!/usr/bin/env python3
"""Update all references after the restructure."""
from __future__ import annotations
import re, sys
from pathlib import Path

HERE = Path.cwd()
CHANGED = 0

def fix(path: Path, old: str, new: str, desc: str = "") -> int:
    global CHANGED
    content = path.read_text(encoding="utf-8", errors="replace")
    count = content.count(old)
    if count == 0:
        return 0
    content = content.replace(old, new)
    path.write_text(content)
    CHANGED += count
    if desc:
        print(f"  {path}: {count}x {desc}")
    return count

def fixre(path: Path, pattern: str, repl: str, desc: str = "") -> int:
    global CHANGED
    content = path.read_text(encoding="utf-8", errors="replace")
    newc, count = re.subn(pattern, repl, content)
    if count == 0:
        return 0
    path.write_text(newc)
    CHANGED += count
    if desc:
        print(f"  {path}: {count}x {desc}")
    return count

IMPORT_MAP = {
    "_core_impl": "lang._core", "core": "lang",
    "bytecode": "lang.bytecode", "analysis_cfg": "lang.analysis_cfg",
    "analysis_model": "lang.analysis_model", "analyze": "lang.analyze",
    "atomic_output": "lang.atomic_output", "cli_common": "lang.cli_common",
    "term_keys": "lang.term_keys", "run_lang": "hosts.run",
    "linux_host": "hosts.linux_host", "linux_job_host": "hosts.linux_job_host",
    "linux_signal_host": "hosts.linux_signal_host",
    "native_compile": "tools.native_compile",
    "_native_compile_impl": "tools._native_compile",
    "sdk_cli": "tools.sdk_cli", "_sdk_cli_impl": "tools._sdk_cli",
}

# ─── Python imports ────────────────────────────────────────
print("=== Python imports ===")
for pyfile in Path("src").rglob("*.py"):
    if pyfile.name == "__init__.py":
        continue
    c = pyfile.read_text(); o = c
    for old, new in IMPORT_MAP.items():
        c = re.sub(rf"(?<!\w)import {old}(?!\w)", f"import {new}", c)
        c = re.sub(rf"(?<!\w)from {old}(?!\w) import", f"from {new} import", c)
    if c != o:
        pyfile.write_text(c); CHANGED += 1; print(f"  {pyfile}")

for pyfile in Path("tests").rglob("*.py"):
    c = pyfile.read_text(); o = c
    for old, new in IMPORT_MAP.items():
        c = re.sub(rf"(?<!\w)import {old}(?!\w)", f"import {new}", c)
        c = re.sub(rf"(?<!\w)from {old}(?!\w) import", f"from {new} import", c)
    if c != o:
        pyfile.write_text(c); CHANGED += 1; print(f"  {pyfile}")

# ─── Shell scripts ─────────────────────────────────────────
print("\n=== Shell scripts ===")
for shfile in Path("scripts").glob("*"):
    if not shfile.name.endswith(".sh") and shfile.name not in ["lace", "lcheck", "lsyntax", "le", "l-lsp", "json-lsp", "ini-lsp"]:
        continue
    try:
        c = shfile.read_text()
    except:
        continue
    o = c
    # These are launched from scripts/ so root is one level up
    if shfile.name in ["lace", "lcheck", "lsyntax", "le", "l-lsp", "json-lsp", "ini-lsp"]:
        c = c.replace('$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)', '$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)')
    c = c.replace('"$HERE/bootstrap/', '"$HERE/src/lang/')
    c = c.replace('"$HERE/runtime/', '"$HERE/src/vm/')
    c = c.replace('"$HERE/conformance/', '"$HERE/tests/')
    c = c.replace('"$HERE/lib/portable/', '"$HERE/lib/core/')
    c = c.replace('"$HERE/lib/hosted/', '"$HERE/lib/host/')
    c = c.replace('"$HERE/build.sh"', '"$HERE/scripts/build.sh"')
    c = c.replace('"$HERE/test.sh"', '"$HERE/scripts/test.sh"')
    c = c.replace('"$HERE/lc', '"$HERE/scripts/lc')
    c = c.replace('"$HERE/lr', '"$HERE/scripts/lr')
    c = c.replace('"$HERE/lace', '"$HERE/scripts/lace')
    c = c.replace('"$HERE/lcheck', '"$HERE/scripts/lcheck')
    c = c.replace('"$HERE/lsyntax', '"$HERE/scripts/lsyntax')
    if c != o:
        shfile.write_text(c); CHANGED += 1; print(f"  {shfile}")

# ─── Python entry points (lc, lr) ──────────────────────────
print("\n=== Python entry points ===")
for pyentry in ["scripts/lc", "scripts/lr"]:
    p = Path(pyentry)
    if not p.exists():
        continue
    c = p.read_text(); o = c
    c = c.replace("HERE=Path(__file__).resolve().parent", "HERE=Path(__file__).resolve().parent.parent\nsys.path.insert(0, str(HERE / 'src'))")
    if c != o:
        p.write_text(c); CHANGED += 1; print(f"  {p}")

# ─── DOCS ──────────────────────────────────────────────────
print("\n=== Docs ===")
DOC_MAP = [
    (r'\b00-ARCHITECTURE\.md\b', 'architecture/00-architecture.md'),
    (r'\b01-CORE-LANGUAGE\.md\b', 'language/01-core-language.md'),
    (r'\b02-GRAMMAR\.ebnf\b', 'language/02-grammar.ebnf'),
    (r'\b03-CORE-SEMANTICS\.md\b', 'language/03-core-semantics.md'),
    (r'\b04-CONFORMANCE\.md\b', 'language/04-conformance.md'),
    (r'\b05-HOST-MODULE-INTERFACE\.md\b', 'language/05-host-module-interface.md'),
    (r'\b06-LIBRARIES\.md\b', 'architecture/06-libraries.md'),
    (r'\b07-IMPLEMENTATION-GUIDE\.md\b', 'guides/07-implementation-guide.md'),
    (r'\b08-TOOLCHAIN-AND-STATUS\.md\b', 'guides/08-toolchain-and-status.md'),
    (r'\b09-DESIGN-RATIONALE\.md\b', 'design/09-design-rationale.md'),
    (r'\b10-OPEN-QUESTIONS\.md\b', 'design/10-open-questions.md'),
    (r'\b11-CODE-ANALYSIS\.md\b', 'guides/11-code-analysis.md'),
    (r'\b12-LANGUAGE-TOUR\.md\b', 'language/12-language-tour.md'),
    (r'\b13-ROADMAP\.md\b', 'guides/13-roadmap.md'),
    (r'\b14-SELF-HOSTING\.md\b', 'guides/14-self-hosting.md'),
    (r'\b15-PORTABLE-LIBRARY\.md\b', 'architecture/15-portable-library.md'),
]
for docfile in Path("docs").rglob("*.md"):
    c = docfile.read_text(); o = c
    for pat, repl in DOC_MAP:
        c = re.sub(pat, repl, c)
    c = re.sub(r'lib/portable/', 'lib/core/', c)
    c = re.sub(r'lib/hosted/', 'lib/host/', c)
    c = re.sub(r'\bbootstrap/', 'src/lang/', c)
    c = re.sub(r'\bruntime/', 'src/vm/', c)
    c = re.sub(r'\bconformance/', 'tests/', c)
    c = re.sub(r'tools/lace2/', 'tools/lace/', c)
    if c != o:
        docfile.write_text(c); CHANGED += 1; print(f"  {docfile}")

# ─── Root files (README, etc) ──────────────────────────────
print("\n=== Root files ===")
for f in ["README.md", "AGENTS.md", "CONTRIBUTING.md", "LICENSE", ".gitignore", ".gitattributes"]:
    p = Path(f)
    if not p.exists():
        continue
    c = p.read_text(); o = c
    c = c.replace('bootstrap/', 'src/lang/')
    c = c.replace('runtime/', 'src/vm/')
    c = c.replace('conformance/', 'tests/')
    c = c.replace('lib/portable/', 'lib/core/')
    c = c.replace('lib/hosted/', 'lib/host/')
    c = c.replace('tools/lace2/', 'tools/lace/')
    c = c.replace('tools/syntax/', 'tools/check/')
    if c != o:
        p.write_text(c); CHANGED += 1; print(f"  {f}")

print(f"\nTotal: {CHANGED} references updated")