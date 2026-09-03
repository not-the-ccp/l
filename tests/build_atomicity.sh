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

# Direct user compilation has the same publication guarantee. The fake C
# compiler deliberately creates/truncates its requested -o path before failing;
# that file must only ever be the private staged path, never the destination.
SOURCE="$TMP/program.l"
OUTPUT="$TMP/program"
FAIL_CC="$TMP/fail-cc"
cat >"$SOURCE" <<'EOF'
fn main() -> i64 { return 0; }
EOF
printf 'known-good\n' >"$OUTPUT"
cat >"$FAIL_CC" <<'EOF'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-o' ]; then
        shift
        out=$1
        break
    fi
    shift
done
test -n "$out"
printf 'broken\n' >"$out"
exit 23
EOF
chmod +x "$FAIL_CC"

if "$HERE/lc" "$SOURCE" -o "$OUTPUT" --cc "$FAIL_CC" >/dev/null 2>&1; then
    echo 'lc unexpectedly succeeded with a failing C compiler' >&2
    exit 1
fi
test "$(cat "$OUTPUT")" = 'known-good'
if find "$TMP" -mindepth 1 -maxdepth 1 -type d -name '.program.stage-*' | grep -q .; then
    echo 'lc left an output staging directory after compiler failure' >&2
    exit 1
fi

"$HERE/lc" "$SOURCE" -o "$OUTPUT" >/dev/null
"$OUTPUT"
if find "$TMP" -mindepth 1 -maxdepth 1 -type d -name '.program.stage-*' | grep -q .; then
    echo 'lc left an output staging directory after success' >&2
    exit 1
fi

printf 'atomic build/output failure handling PASS\n'
