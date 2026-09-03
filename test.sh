#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
"$HERE/build.sh" tools
"$HERE/tests/build_atomicity.sh"
"$PYTHON" "$HERE/conformance/core_conformance.py"
"$PYTHON" "$HERE/tests/const_arrays.py"
"$HERE/lr" "$HERE/tests/utf8_portable.l" >/dev/null
"$HERE/lr" "$HERE/tests/byte_display_portable.l" >/dev/null
"$HERE/lc" --check "$HERE/examples/hosted/project/main.l" >/dev/null
"$HERE/lr" "$HERE/examples/hosted/hello.l" -- smoke >/dev/null

# Portable-library stress: run representative library workloads through the
# native compiler without relying on host capabilities.
"$HERE/lr" "$HERE/examples/portable/collections_demo.l" >/dev/null
"$HERE/lr" "$HERE/examples/portable/bytes_demo.l" >/dev/null
"$HERE/lr" "$HERE/examples/portable/const_readers_demo.l" >/dev/null

# Shell parsing and human-interface models are ordinary L consumers. Keep them
# executable through the native toolchain so parsing, source spans, byte-safe
# editing, prompt semantics, history and terminal layout stay in lockstep with L.
"$HERE/lr" "$HERE/tools/shell/syntax_test.l" >/dev/null
"$HERE/lr" "$HERE/tools/shell/presentation_test.l" >/dev/null
"$HERE/lr" "$HERE/tools/shell/history_test.l" >/dev/null
"$HERE/lr" "$HERE/tools/shell/prompt_test.l" >/dev/null
"$HERE/lr" "$HERE/tools/shell/editor_test.l" >/dev/null
"$HERE/lr" --root "$HERE" "$HERE/tools/shell/terminal_ui_test.l" >/dev/null
"$HERE/lc" --check --root "$HERE" "$HERE/tools/shell/main.l" >/dev/null

# Linux hosted-profile parity. Exercise the exact same L programs once through
# the Python reference host and once through the generated native runtime.
# The process probe covers owned/duplicated FDs, partial I/O + EOF, synchronous
# exec failure, explicit stdio wiring, process groups, signals, waits, and a
# real three-process byte-stream pipeline. The context probe covers cwd changes
# plus raw byte environment lookup/enumeration/mutation and error paths. The
# shell executor adds PATH resolution, per-stage status, launch rollback and
# persistent shell-owned cwd/environment state.
if [ "$(uname -s)" = Linux ]; then
  "$HERE/lr" "$HERE/tools/shell/executor_test.l" >/dev/null
  "$HERE/lr" "$HERE/tools/shell/state_test.l" >/dev/null

  linux_ref=$("$PYTHON" "$HERE/bootstrap/sdk_cli.py" run "$HERE/examples/hosted/linux_process_probe.l")
  test "$linux_ref" = '3'
  "$PYTHON" "$HERE/bootstrap/sdk_cli.py" run "$HERE/examples/hosted/linux_context_probe.l"

  linux_bin=$(mktemp)
  context_bin=$(mktemp)
  rm -f "$linux_bin" "$context_bin"
  trap 'rm -f "$linux_bin" "$context_bin"' EXIT HUP INT TERM
  "$HERE/lc" "$HERE/examples/hosted/linux_process_probe.l" -o "$linux_bin" >/dev/null
  linux_native=$("$linux_bin")
  test "$linux_native" = '3'
  "$HERE/lc" "$HERE/examples/hosted/linux_context_probe.l" -o "$context_bin" >/dev/null
  "$context_bin"
  rm -f "$linux_bin" "$context_bin"
  trap - EXIT HUP INT TERM
fi

# Lace rewrite kernel and v1 editor semantics.
"$HERE/lr" --root "$HERE" "$HERE/tools/lace2/kernel_test.l" >/dev/null
"$HERE/lr" --root "$HERE" "$HERE/tools/lace2/navigation_test.l" >/dev/null
"$HERE/lr" --root "$HERE" "$HERE/tools/lace2/editor_model_test.l" >/dev/null
"$HERE/lr" --root "$HERE" "$HERE/tools/lace2/linewise_test.l" >/dev/null
"$HERE/lr" --root "$HERE" "$HERE/tools/lace2/render_test.l" >/dev/null
"$HERE/lc" --check --root "$HERE" "$HERE/tools/lace2/main.l" >/dev/null

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
for t in term_key_events.py code_analysis.py incremental_lsp.py editor_safety.py highlight_stability.py editor_usability.py editor_display.py editor_pty.py lace2_pty.py; do
  "$PYTHON" "$HERE/tests/$t"
done
echo 'L repository test suite PASS'
