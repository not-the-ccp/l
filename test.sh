#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
"$HERE/build.sh" tools
"$PYTHON" "$HERE/conformance/core_conformance.py"
"$HERE/lc" --check "$HERE/examples/hosted/project/main.l" >/dev/null
"$HERE/lr" "$HERE/examples/hosted/hello.l" -- smoke >/dev/null

# First self-hosting slice: the syntax frontend is written in L and runs as a
# native executable. Check both acceptance and rejection so this cannot regress
# into a build-only demo.
"$HERE/build/lsyntax" "$HERE/examples/core/linked_list.l" >/dev/null
"$HERE/build/lsyntax" "$HERE/tools/lace/lace.l" >/dev/null
bad=$(mktemp)
trap 'rm -f "$bad"' EXIT HUP INT TERM
printf 'fn broken( {\n' >"$bad"
if "$HERE/build/lsyntax" "$bad" >/dev/null 2>&1; then
  echo 'lsyntax accepted malformed source' >&2
  exit 1
fi
rm -f "$bad"
trap - EXIT HUP INT TERM

for t in code_analysis.py incremental_lsp.py editor_safety.py highlight_stability.py editor_usability.py editor_display.py editor_pty.py; do
  "$PYTHON" "$HERE/tests/$t"
done
echo 'L repository test suite PASS'
