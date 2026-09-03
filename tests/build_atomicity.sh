#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BUILD="$TMP/build"
mkdir -p "$BUILD"

# A failed rebuild must not replace the last known-good tool or leave staging
# debris that can be mistaken for a published binary.
printf 'known-good\n' >"$BUILD/lace"
if BUILD_DIR="$BUILD" CC=false "$HERE/build.sh" lace >/dev/null 2>&1; then
    echo 'build.sh unexpectedly succeeded with a failing C compiler' >&2
    exit 1
fi
test "$(cat "$BUILD/lace")" = 'known-good'
if find "$BUILD" -mindepth 1 -maxdepth 1 -name '.stage.*' | grep -q .; then
    echo 'build.sh left a staging directory after failure' >&2
    exit 1
fi

printf 'atomic tool build failure handling PASS\n'
