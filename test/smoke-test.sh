#!/bin/sh
# Smoke tests for vzz. Builds a tiny real video with ffmpeg and exercises
# the binary's argument handling and a couple of end-to-end playback paths.
# Usage: test/smoke-test.sh [path-to-vzz-binary]

set -eu

VZZ="${1:-bin/vzz}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

[ -x "$VZZ" ] || fail "binary not found or not executable: $VZZ"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required to run the smoke tests"

VIDEO="$WORKDIR/test.mp4"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=duration=10:size=320x240:rate=15" \
  -f lavfi -i "sine=frequency=440:duration=10" \
  -shortest -c:v libx264 -c:a aac "$VIDEO"

# --help exits 0
"$VZZ" --help >/dev/null 2>&1 || fail "--help should exit 0"
pass "--help exits 0"

# missing arguments exit 1
if "$VZZ" >/dev/null 2>&1; then fail "no args should exit nonzero"; fi
pass "missing VIDEO_FILE/--duration exits nonzero"

# missing video file exits 1
if "$VZZ" "$WORKDIR/nope.mp4" --duration 5 >/dev/null 2>&1; then
  fail "missing video file should exit nonzero"
fi
pass "missing video file exits nonzero"

# non-numeric --duration exits 1
if "$VZZ" "$VIDEO" --duration abc >/dev/null 2>&1; then
  fail "non-numeric --duration should exit nonzero"
fi
pass "non-numeric --duration exits nonzero"

# fade point past --duration exits 1
if "$VZZ" "$VIDEO" --duration 1 --fade-audio-at 2 >/dev/null 2>&1; then
  fail "--fade-audio-at past --duration should exit nonzero"
fi
pass "--fade-audio-at past --duration exits nonzero"

# mpv not found on PATH exits nonzero with a clean message, no crash trace
MPV_DIR=$(dirname "$(command -v mpv)")
NO_MPV_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^$MPV_DIR\$" | paste -sd: -)
OUT=$(PATH="$NO_MPV_PATH" "$VZZ" "$VIDEO" --duration 0.05 2>&1) && STATUS=0 || STATUS=$?
[ "$STATUS" -ne 0 ] || fail "missing mpv should exit nonzero"
echo "$OUT" | grep -q "mpv not found" || fail "missing mpv should print a clean error, got: $OUT"
pass "missing mpv exits nonzero with a clean message"

# mpv rejecting the input file exits nonzero, no crash trace
BADFILE="$WORKDIR/bad.mp4"
echo "not a real video" > "$BADFILE"
if "$VZZ" "$BADFILE" --duration 1 >/dev/null 2>&1; then
  fail "a file mpv can't play should exit nonzero"
fi
pass "a file mpv can't play exits nonzero"

# full natural-stop run with both fades: should exit 0 and finish quickly
START=$(date +%s)
"$VZZ" "$VIDEO" --duration 0.1 --fade-audio-at 0.03 --fade-video-at 0.05 >"$WORKDIR/run.log" 2>&1
STATUS=$?
END=$(date +%s)
[ "$STATUS" -eq 0 ] || fail "natural-stop run should exit 0 (log: $(cat "$WORKDIR/run.log"))"
ELAPSED=$((END - START))
[ "$ELAPSED" -le 15 ] || fail "natural-stop run took too long: ${ELAPSED}s"
if grep -qi "error\|warn" "$WORKDIR/run.log"; then
  fail "natural-stop run logged errors/warnings: $(cat "$WORKDIR/run.log")"
fi
pass "natural-stop run with fades exits 0 in ${ELAPSED}s with no errors"

echo "all smoke tests passed"
