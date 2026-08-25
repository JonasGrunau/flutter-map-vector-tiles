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
[[ -d ios ]] || flutter create --platforms=ios .

flutter run --profile -d "$DEVICE" \
  --dart-define=BENCH_LABEL="$LABEL" \
  --dart-define=BENCH_LO="$LO" \
  --dart-define=BENCH_HI="$HI" > "$OUT" 2>&1 &
PID=$!

for _ in $(seq 1 180); do
  sleep 5
  grep -q "===== END =====" "$OUT" 2>/dev/null && break
  grep -qE "BUILD FAILED|Error launching" "$OUT" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
done

kill $PID 2>/dev/null || true
sleep 2
pkill -9 -f "flutter_tools.snapshot run" 2>/dev/null || true

echo "--- $LABEL ---"
grep -E "^flutter: BENCH\[" "$OUT" || echo "no results; see $OUT"
