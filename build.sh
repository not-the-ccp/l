#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
CC=${CC:-cc}
mkdir -p "$HERE/build"
build_one() {
    kind=$1 out=$2
    "$PYTHON" "$HERE/bootstrap/native_compile.py" --tool "$kind" --cc "$CC" -o "$HERE/build/$out"
}
build_lace() {
    CC="$CC" "$HERE/lc" --root "$HERE" "$HERE/tools/lace2/main.l" -o "$HERE/build/lace" >/dev/null
}
build_syntax() {
    CC="$CC" "$HERE/lc" "$HERE/tools/syntax/lsyntax.l" -o "$HERE/build/lsyntax" >/dev/null
}
build_check() {
    CC="$CC" "$HERE/lc" "$HERE/tools/check/lcheck.l" -o "$HERE/build/lcheck" >/dev/null
}
case "${1:-all}" in
  all|tools)
    build_lace
    # One transition escape hatch while the rewrite becomes the sole editor.
    build_one editor lace-legacy
    build_one lsp-l l-lsp
    build_one lsp-json json-lsp
    build_one lsp-ini ini-lsp
    build_syntax
    build_check
    ;;
  lace|lace-next) build_lace ;;
  lace-legacy) build_one editor lace-legacy ;;
  l-lsp) build_one lsp-l l-lsp ;;
  json-lsp) build_one lsp-json json-lsp ;;
  ini-lsp) build_one lsp-ini ini-lsp ;;
  lsyntax) build_syntax ;;
  lcheck) build_check ;;
  clean) rm -rf "$HERE/build" ;;
  *) echo "usage: ./build.sh [all|tools|lace|lace-next|lace-legacy|l-lsp|json-lsp|ini-lsp|lsyntax|lcheck|clean]" >&2; exit 2 ;;
esac
