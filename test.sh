#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
"$HERE/build.sh" tools
"$PYTHON" "$HERE/conformance/core_conformance.py"
"$HERE/lc" --check "$HERE/examples/hosted/project/main.l" >/dev/null
"$HERE/lr" "$HERE/examples/hosted/hello.l" -- smoke >/dev/null
for t in code_analysis.py incremental_lsp.py editor_safety.py highlight_stability.py editor_usability.py editor_display.py editor_pty.py; do
  "$PYTHON" "$HERE/tests/$t"
done
echo 'L repository test suite PASS'
