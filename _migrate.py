#!/usr/bin/env python3
"""Execute the complete restructure using git mv."""
from __future__ import annotations
import os, subprocess, sys
from pathlib import Path

HERE = Path.cwd()
os.chdir(HERE)

def git(cmd: str) -> None:
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FAIL: {cmd}\n{r.stderr}", file=sys.stderr)
        sys.exit(1)

def mv(src: str, dst: str) -> None:
    git(f"git mv {src} {dst}")

def mkdir(d: str) -> None:
    Path(d).mkdir(parents=True, exist_ok=True)

def write(f: str, c: str) -> None:
    Path(f).write_text(c)
    git(f"git add {f}")

# Create new dirs
for d in ["src/lang", "src/hosts", "src/vm", "src/tools",
          "lib/core", "lib/slang", "lib/host",
          "scripts", "tests", "ci/workflows", "ci/issue-templates",
          "docs/language", "docs/architecture", "docs/guides", "docs/design"]:
    mkdir(d)
    # Add placeholder so git tracks the dir
    write(f"{d}/.gitkeep", "")

# Move Python compiler
print("=== Python compiler → src/lang/ ===")
for f in ["_core_impl.py", "bytecode.py", "analysis_cfg.py", "analysis_model.py",
          "analyze.py", "atomic_output.py", "cli_common.py", "term_keys.py"]:
    mv(f"bootstrap/{f}", f"src/lang/{f}")
# Rename monolith
git("git mv src/lang/_core_impl.py src/lang/_core.py")
# Create __init__.py from core.py
import re
bc = Path("bootstrap/core.py").read_text()
bc = bc.replace("import _core_impl as _impl", "from lang import _core as _impl")
bc = re.sub(r"\nfrom const_arrays.*", "", bc)
bc = re.sub(r"\nfrom literal_ranges.*", "", bc)
bc = re.sub(r"\n_install_const_arrays\(\)", "", bc)
bc = re.sub(r"\n_install_literal_ranges\(\)", "", bc)
write("src/lang/__init__.py", bc)

# Move host modules
print("=== Host modules → src/hosts/ ===")
mv("bootstrap/run_lang.py", "src/hosts/run.py")
for f in ["linux_host.py", "linux_job_host.py", "linux_signal_host.py"]:
    mv(f"bootstrap/{f}", f"src/hosts/{f}")
write("src/hosts/__init__.py", "")

# Move Python tools
print("=== Python tools → src/tools/ ===")
for f in ["native_compile.py", "_native_compile_impl.py",
          "sdk_cli.py", "_sdk_cli_impl.py"]:
    mv(f"bootstrap/{f}", f"src/tools/{f}")
git("git mv src/tools/_native_compile_impl.py src/tools/_native_compile.py")
git("git mv src/tools/_sdk_cli_impl.py src/tools/_sdk_cli.py")
write("src/tools/__init__.py", "")

# Move const_policy.py
print("=== const_policy.py → src/tools/ ===")
mv("tools/const_policy.py", "src/tools/const_policy.py")

# Move C runtime
print("=== C runtime → src/vm/ ===")
for f in ["native_vm.c", "native_vm.h", "native_embed.c", "native_embed.h"]:
    mv(f"runtime/{f}", f"src/vm/{f}")

# Move portable L libs
print("=== L libraries ===")
for f in Path("lib/portable").glob("*.l"):
    if f.name.startswith("slang_"):
        mv(f"lib/portable/{f.name}", f"lib/slang/{f.name.replace('slang_', '')}")
    elif f.name == "lsp.l":
        mv(f"lib/portable/lsp.l", "lib/core/lsp.l")
    elif f.name == "json.l":
        mv(f"lib/portable/json.l", "lib/core/json.l")
    else:
        mv(f"lib/portable/{f.name}", f"lib/core/{f.name}")

# Move host L lib
mv("lib/hosted/lsp_client.l", "lib/host/lsp_client.l")

# Move scripts
print("=== Scripts → scripts/ ===")
for f in ["lace", "lc", "lr", "lcheck", "lsyntax", "le",
          "l-lsp", "json-lsp", "ini-lsp", "build.sh", "test.sh", "Makefile"]:
    if Path(f).exists():
        mv(f, f"scripts/{f}")

# Move conformance
print("=== Tests ===")
mv("conformance/core_conformance.py", "tests/core_conformance.py")

# Move CI
print("=== CI → ci/ ===")
for src, dst in [
    (".github/workflows/ci.yml", "ci/workflows/ci.yml"),
    (".github/workflows/lace-release.yml", "ci/workflows/lace-release.yml"),
    (".github/ISSUE_TEMPLATE/bug.md", "ci/issue-templates/bug.md"),
    (".github/ISSUE_TEMPLATE/design.md", "ci/issue-templates/design.md"),
]:
    mv(src, dst)

# Move docs
print("=== Docs ===")
docs = {
    "00-ARCHITECTURE.md": "architecture/00-architecture.md",
    "06-LIBRARIES.md": "architecture/06-libraries.md",
    "15-PORTABLE-LIBRARY.md": "architecture/15-portable-library.md",
    "01-CORE-LANGUAGE.md": "language/01-core-language.md",
    "02-GRAMMAR.ebnf": "language/02-grammar.ebnf",
    "03-CORE-SEMANTICS.md": "language/03-core-semantics.md",
    "04-CONFORMANCE.md": "language/04-conformance.md",
    "05-HOST-MODULE-INTERFACE.md": "language/05-host-module-interface.md",
    "12-LANGUAGE-TOUR.md": "language/12-language-tour.md",
    "07-IMPLEMENTATION-GUIDE.md": "guides/07-implementation-guide.md",
    "08-TOOLCHAIN-AND-STATUS.md": "guides/08-toolchain-and-status.md",
    "11-CODE-ANALYSIS.md": "guides/11-code-analysis.md",
    "13-ROADMAP.md": "guides/13-roadmap.md",
    "14-SELF-HOSTING.md": "guides/14-self-hosting.md",
    "09-DESIGN-RATIONALE.md": "design/09-design-rationale.md",
    "10-OPEN-QUESTIONS.md": "design/10-open-questions.md",
    "const-array-selfhost.md": "design/const-array-selfhost.md",
}
for old, new in docs.items():
    mv(f"docs/{old}", f"docs/{new}")

# Move README.md in docs
mv("docs/README.md", "docs/index.md")

print("\n=== Migration done! ===")
print("Now run: python3 _update_refs.py to update all references")
