#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
"$HERE/build.sh" tools
"$PYTHON" "$HERE/conformance/core_conformance.py"
"$HERE/lc" --check "$HERE/examples/hosted/project/main.l" >/dev/null
"$HERE/lr" "$HERE/examples/hosted/hello.l" -- smoke >/dev/null

# Portable-library stress: this runs through the bytecode VM and exercises
# generic stack/queue/heap/map/set code including queue compaction and map
# rehashing. It deliberately uses no host APIs itself.
"$HERE/lr" "$HERE/examples/portable/collections_demo.l" >/dev/null

# Self-hosting frontend slices run as native executables. Check syntax,
# top-level identity, full body-AST traversal on small and substantial real
# programs, and semantic checking of a real Core program.
"$HERE/build/lsyntax" "$HERE/examples/core/linked_list.l" >/dev/null
"$HERE/build/lsyntax" "$HERE/tools/lace/lace.l" >/dev/null
outline=$("$HERE/build/lsyntax" --outline "$HERE/examples/core/linked_list.l")
printf '%s\n' "$outline" | grep -q '^struct Node$'
printf '%s\n' "$outline" | grep -q '^fn prepend$'
printf '%s\n' "$outline" | grep -q '^fn sum$'
ast=$("$HERE/build/lsyntax" --ast "$HERE/examples/core/linked_list.l")
printf '%s\n' "$ast" | grep -q '^fn prepend$'
printf '%s\n' "$ast" | grep -q '^[[:space:]]*return$'
"$HERE/build/lsyntax" --ast "$HERE/tools/lace/lace.l" >/dev/null
"$HERE/build/lcheck" "$HERE/examples/core/linked_list.l" >/dev/null

bad=$(mktemp)
trap 'rm -f "$bad"' EXIT HUP INT TERM
printf 'fn broken( {\n' >"$bad"
if "$HERE/build/lsyntax" "$bad" >/dev/null 2>&1; then
  echo 'lsyntax accepted malformed source' >&2
  exit 1
fi
printf 'fn main() -> i64 { var x: bool = 1; return 0; }\n' >"$bad"
if "$HERE/build/lcheck" "$bad" >/dev/null 2>&1; then
  echo 'lcheck accepted an invalid typed program' >&2
  exit 1
fi
rm -f "$bad"
trap - EXIT HUP INT TERM

"$PYTHON" "$HERE/tests/selfhost_checker_diff.py"
for t in code_analysis.py incremental_lsp.py editor_safety.py highlight_stability.py editor_usability.py editor_display.py editor_pty.py; do
  "$PYTHON" "$HERE/tests/$t"
done
echo 'L repository test suite PASS'
