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
build_lace_next() {
    CC="$CC" "$HERE/lc" --root "$HERE" "$HERE/tools/lace2/main.l" -o "$HERE/build/lace-next" >/dev/null
}
build_syntax() {
    CC="$CC" "$HERE/lc" "$HERE/tools/syntax/lsyntax.l" -o "$HERE/build/lsyntax" >/dev/null
}
build_check() {
    CC="$CC" "$HERE/lc" "$HERE/tools/check/lcheck.l" -o "$HERE/build/lcheck" >/dev/null
}
case "${1:-all}" in
  all|tools)
    # Keep the previous editor available until the rewrite's PTY suite is
    # strong enough to replace it, but always build the rewrite for dogfood.
    build_one editor lace
    build_lace_next
    build_one lsp-l l-lsp
    build_one lsp-json json-lsp
    build_one lsp-ini ini-lsp
    build_syntax
    build_check
    ;;
  lace) build_one editor lace ;;
  lace-next) build_lace_next ;;
  l-lsp) build_one lsp-l l-lsp ;;
  json-lsp) build_one lsp-json json-lsp ;;
  ini-lsp) build_one lsp-ini ini-lsp ;;
  lsyntax) build_syntax ;;
  lcheck) build_check ;;
  clean) rm -rf "$HERE/build" ;;
  *) echo "usage: ./build.sh [all|tools|lace|lace-next|l-lsp|json-lsp|ini-lsp|lsyntax|lcheck|clean]" >&2; exit 2 ;;
esac
