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
case "${1:-all}" in
  all|tools)
    build_one editor lace
    build_one lsp-l l-lsp
    build_one lsp-json json-lsp
    build_one lsp-ini ini-lsp
    ;;
  lace) build_one editor lace ;;
  l-lsp) build_one lsp-l l-lsp ;;
  json-lsp) build_one lsp-json json-lsp ;;
  ini-lsp) build_one lsp-ini ini-lsp ;;
  clean) rm -rf "$HERE/build" ;;
  *) echo "usage: ./build.sh [all|tools|lace|l-lsp|json-lsp|ini-lsp|clean]" >&2; exit 2 ;;
esac
