#!/bin/bash
set -eu

# ============================================================
# Complete L repository restructure
# Moves everything into a clean from-first-principles layout.
# Run from repo root.
# ============================================================

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# --- Design principles ---
# src/        — Source code *implementing* L (Python compiler, C VM, host modules)
# lib/        — L-language libraries
# tools/      — L-written tool programs
# scripts/    — Build/launch scripts (get them out of root)
# tests/      — Everything test-related
# docs/       — Documentation, consolidated
# ci/         — CI and issue templates
# examples/   — Example programs

echo "=== 1. Create new directory structure ==="
mkdir -p src/lang          # Python bootstrap compiler
mkdir -p src/hosts         # Python host module implementations
mkdir -p src/vm            # C runtime (was runtime/)
mkdir -p src/tools         # Python-side utility tools
mkdir -p lib/core          # Portable stdlib (was lib/portable/, non-slang)
mkdir -p lib/host          # Host-dependent L lib (was lib/hosted/)
mkdir -p lib/slang         # Self-hosted compiler lib (was lib/portable/slang_*)
mkdir -p scripts           # Build/launch scripts
mkdir -p tests             # All test files
mkdir -p ci                # CI config and issue templates
mkdir -p examples          # No change needed

echo "=== 2. Move source files ==="

# Python bootstrap compiler → src/lang/
cp bootstrap/_core_impl.py    src/lang/_core.py
cp bootstrap/core.py          src/lang/core.py
cp bootstrap/bytecode.py      src/lang/bytecode.py
cp bootstrap/analysis_cfg.py  src/lang/analysis_cfg.py
cp bootstrap/analysis_model.py src/lang/analysis_model.py
cp bootstrap/analyze.py       src/lang/analyze.py
cp bootstrap/atomic_output.py src/lang/atomic_output.py
cp bootstrap/cli_common.py    src/lang/cli_common.py
cp bootstrap/term_keys.py     src/lang/term_keys.py

# Python host modules → src/hosts/
cp bootstrap/run_lang.py      src/hosts/run.py
cp bootstrap/linux_host.py    src/hosts/linux_host.py
cp bootstrap/linux_job_host.py src/hosts/linux_job_host.py
cp bootstrap/linux_signal_host.py src/hosts/linux_signal_host.py

# Python tools → src/tools/
cp bootstrap/native_compile.py   src/tools/native_compile.py
cp bootstrap/_native_compile_impl.py src/tools/_native_compile.py
cp bootstrap/sdk_cli.py          src/tools/sdk_cli.py
cp bootstrap/_sdk_cli_impl.py    src/tools/_sdk_cli.py
cp tools/const_policy.py         src/tools/const_policy.py

# C runtime → src/vm/
cp runtime/native_vm.c    src/vm/vm.c
cp runtime/native_vm.h    src/vm/vm.h
cp runtime/native_embed.c src/vm/embed.c
cp runtime/native_embed.h src/vm/embed.h

# Portable stdlib → lib/core/ (everything except slang_*)
for f in lib/portable/*.l; do
    base=$(basename "$f")
    case "$base" in
        slang_*) cp "$f" "lib/slang/$base" ;;
        *)       cp "$f" "lib/core/$base" ;;
    esac
done

# Host lib → lib/host/
cp lib/hosted/lsp_client.l lib/host/lsp_client.l

# Wrapper scripts → scripts/
cp lace    scripts/lace
cp lc      scripts/lc
cp lr      scripts/lr
cp lcheck  scripts/lcheck
cp lsyntax scripts/lsyntax
cp le      scripts/le
cp l-lsp   scripts/l-lsp
cp json-lsp scripts/json-lsp
cp ini-lsp scripts/ini-lsp
cp build.sh scripts/build.sh
cp test.sh scripts/test.sh

# Test files → tests/
cp conformance/core_conformance.py tests/core_conformance.py
cp tests/*.py                      tests/ 2>/dev/null || true
cp tests/*.sh                      tests/ 2>/dev/null || true

# CI config → ci/
cp .github/workflows/ci.yml          ci/ci.yml
cp .github/workflows/lace-release.yml ci/lace-release.yml
cp .github/ISSUE_TEMPLATE/bug.md     ci/bug-template.md
cp .github/ISSUE_TEMPLATE/design.md  ci/design-template.md

# Examples — no change needed, already clean

echo "=== 3. Update Python imports ==="

# All Python files that import from 'core' or 'bootstrap' modules need updating.
# In the new layout:
#   bootstrap/core.py       → src/lang/core.py
#   bootstrap/_core_impl.py → src/lang/_core.py
#   bootstrap/bytecode.py   → src/lang/bytecode.py
#   bootstrap/analysis_*.py → src/lang/analysis_*.py
#   bootstrap/run_lang.py   → src/hosts/run.py
#   bootstrap/linux_*.py    → src/hosts/linux_*.py
#   bootstrap/native_compile.py → src/tools/native_compile.py
#   bootstrap/_native_compile_impl.py → src/tools/_native_compile.py
#   bootstrap/sdk_cli.py    → src/tools/sdk_cli.py
#   bootstrap/_sdk_cli_impl.py → src/tools/_sdk_cli.py

# We need to add src/ to sys.path and update module names.
# Strategy: update every .py file that references old paths.

# Fix imports in src/lang/*.py and src/hosts/*.py and src/tools/*.py
# The key change: old code used `from core import ...` or `import core`.
# In the new layout, src/ is the package root, so imports become:
#   from lang.core import ...
#   from lang.bytecode import ...
#   from hosts.run import ...
#   from tools.native_compile import ...
# etc.

# But this is complex. Let me use a simpler approach: add src/ to sys.path
# in the entry points, and keep the internal imports as-is (they import
# from the same directory for internal code).

# The external importers (tests, conformance, tools) need their imports
# updated to point to the new locations.

echo "=== 4. Update external references ==="

# We'll update the scripts/*.sh callers and test files after migration.

echo "=== 5. Clean up old structure ==="
# Keep original files temporarily until the migration is verified.

echo "=== Migration structure created ==="

# Print new structure
find src lib scripts tests ci -type f | sort