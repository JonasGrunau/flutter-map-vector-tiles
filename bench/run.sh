#!/bin/zsh
# Build, run and harvest one bench run, then get out of the way.
#
#   ./run.sh <device-id> [label] [lo10] [hi10]
#
# Profile mode is mandatory: debug distorts the UI thread badly enough to be
# useless, and iOS simulators cannot run profile at all (nor do they reproduce
# GPU-bound costs — the host GPU is far too fast). Use a real device.
set -e
DEVICE="${1:?usage: run.sh <device-id> [label] [lo10] [hi10]}"
LABEL="${2:-run}"
LO="${3:-163}"
HI="${4:-177}"
OUT="/tmp/bench-$LABEL.log"

cd "$(dirname "$0")"
if [[ ! -d ios ]]; then
  flutter create --platforms=ios .
  # `flutter create` also drops two files that break the repo's analyzer:
  # an analysis_options.yaml that overrides the root lints, and a default
  # widget_test.dart that references a `MyApp` this harness does not have.
  # Both are gitignored, but `flutter analyze` at the repo root still reads
  # them — so a first run would leave 18 errors behind.
  rm -f analysis_options.yaml test/widget_test.dart
  rmdir test 2>/dev/null || true
fi

# STYLE_URL / MAPTILER_KEY / BENCH_SETUP / BENCH_MODE / BENCH_LAT_E5 /
# BENCH_LON_E5 / BENCH_LOG_GONE / BENCH_WATCH pass through from the environment
# when set, so app-specific styles and keys are given per invocation and
# never land in this repo.
flutter run --profile -d "$DEVICE" \
  --dart-define=BENCH_LABEL="$LABEL" \
  --dart-define=BENCH_LO="$LO" \
  --dart-define=BENCH_HI="$HI" \
  ${STYLE_URL:+--dart-define=STYLE_URL=$STYLE_URL} \
  ${MAPTILER_KEY:+--dart-define=MAPTILER_KEY=$MAPTILER_KEY} \
  ${BENCH_SETUP:+--dart-define=BENCH_SETUP=$BENCH_SETUP} \
  ${BENCH_MODE:+--dart-define=BENCH_MODE=$BENCH_MODE} \
  ${BENCH_LAT_E5:+--dart-define=BENCH_LAT_E5=$BENCH_LAT_E5} \
  ${BENCH_LON_E5:+--dart-define=BENCH_LON_E5=$BENCH_LON_E5} \
  ${BENCH_LOG_GONE:+--dart-define=BENCH_LOG_GONE=$BENCH_LOG_GONE} \
  ${BENCH_WATCH:+--dart-define=BENCH_WATCH=$BENCH_WATCH} > "$OUT" 2>&1 &
PID=$!

for _ in $(seq 1 180); do
  sleep 5
  grep -q "===== END =====" "$OUT" 2>/dev/null && break
  grep -qE "BUILD FAILED|Error launching" "$OUT" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
done

# `$!` is the flutter tool's own Dart process (the wrapper scripts exec into
# it). Kill that process and its children only: another `flutter run` on this
# machine belongs to someone else. List the children before the tool goes:
# once it has exited they belong to launchd, and `pkill -P` finds none.
CHILDREN=($(pgrep -P $PID 2>/dev/null || true))
kill $PID 2>/dev/null || true
sleep 2
for child in $CHILDREN; do
  # Still the tool's child, or orphaned by it: not a reused PID.
  [[ "$(ps -o ppid= -p $child 2>/dev/null | tr -d ' ')" == ($PID|1) ]] &&
    kill -9 $child 2>/dev/null || true
done
# Only if the tool is still running, and still ours: its PID may have been
# reused since it exited.
[[ "$(ps -o ppid= -p $PID 2>/dev/null | tr -d ' ')" == "$$" ]] &&
  kill -9 $PID 2>/dev/null || true

echo "--- $LABEL ---"
# iOS logs as `flutter: …`, Android as `I/flutter (<pid>): …`.
RESULTS=$(grep -E "^(flutter|I/flutter \( *[0-9]+\)): BENCH\[" "$OUT" \
  | sed -E 's/^(flutter|I\/flutter \( *[0-9]+\)): //')
echo "${RESULTS:-no results; see $OUT}"
