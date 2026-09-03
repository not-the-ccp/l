#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
CC=${CC:-cc}
BUILD_DIR=${BUILD_DIR:-"$HERE/build"}
mkdir -p "$BUILD_DIR"

STAGE=
cleanup_stage() {
    if [ -n "${STAGE:-}" ]; then
        rm -rf "$STAGE"
        STAGE=
    fi
}
trap cleanup_stage EXIT HUP INT TERM

begin_stage() {
    cleanup_stage
    STAGE=$(mktemp -d "$BUILD_DIR/.stage.XXXXXX")
}

publish_stage() {
    for name in "$@"; do
        test -f "$STAGE/$name"
    done
    for name in "$@"; do
        mv -f "$STAGE/$name" "$BUILD_DIR/$name"
    done
    rm -rf "$STAGE"
    STAGE=
}

build_one() {
    kind=$1 out=$2 dest=$3
    "$PYTHON" "$HERE/bootstrap/native_compile.py" --tool "$kind" --cc "$CC" -o "$dest/$out"
}
build_lace() {
    dest=$1
    CC="$CC" "$HERE/lc" --root "$HERE" "$HERE/tools/lace2/main.l" -o "$dest/lace" >/dev/null
}
build_lace_legacy() {
    dest=$1
    build_one editor lace-legacy "$dest"
}
build_l_lsp() {
    dest=$1
    build_one lsp-l l-lsp "$dest"
}
build_json_lsp() {
    dest=$1
    build_one lsp-json json-lsp "$dest"
}
build_ini_lsp() {
    dest=$1
    build_one lsp-ini ini-lsp "$dest"
}
build_syntax() {
    dest=$1
    CC="$CC" "$HERE/lc" "$HERE/tools/syntax/lsyntax.l" -o "$dest/lsyntax" >/dev/null
}
build_check() {
    dest=$1
    CC="$CC" "$HERE/lc" "$HERE/tools/check/lcheck.l" -o "$dest/lcheck" >/dev/null
}

build_single() {
    name=$1 builder=$2
    begin_stage
    "$builder" "$STAGE"
    publish_stage "$name"
}

build_tools() {
    begin_stage
    build_lace "$STAGE"
    # One transition escape hatch while the rewrite becomes the sole editor.
    build_lace_legacy "$STAGE"
    build_l_lsp "$STAGE"
    build_json_lsp "$STAGE"
    build_ini_lsp "$STAGE"
    build_syntax "$STAGE"
    build_check "$STAGE"
    publish_stage lace lace-legacy l-lsp json-lsp ini-lsp lsyntax lcheck
}

case "${1:-all}" in
  all|tools) build_tools ;;
  lace|lace-next) build_single lace build_lace ;;
  lace-legacy) build_single lace-legacy build_lace_legacy ;;
  l-lsp) build_single l-lsp build_l_lsp ;;
  json-lsp) build_single json-lsp build_json_lsp ;;
  ini-lsp) build_single ini-lsp build_ini_lsp ;;
  lsyntax) build_single lsyntax build_syntax ;;
  lcheck) build_single lcheck build_check ;;
  clean) cleanup_stage; rm -rf "$BUILD_DIR" ;;
  *) echo "usage: ./build.sh [all|tools|lace|lace-next|lace-legacy|l-lsp|json-lsp|ini-lsp|lsyntax|lcheck|clean]" >&2; exit 2 ;;
esac
