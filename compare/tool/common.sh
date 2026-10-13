# Shared by the run scripts: build metadata, scaffolds, the lab server and
# the cleanup on the way out. Sourced, not executed, as the scripts' first
# command: the traps below must be in place before anything they undo.

COMPARE_DIR="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
REPO_DIR="$(cd "$COMPARE_DIR/.." && pwd)"
LAB_PORT="${LAB_PORT:-8790}"
LAB="http://localhost:$LAB_PORT"

# Every way out runs the CLEANUP steps: the end of the script, a failed
# command under `set -e`, Ctrl-C, a kill. A script that changes more than
# the lab server appends a step once there is something to undo. Set here,
# at the top level of the sourcing script: zsh runs an EXIT trap set inside
# a function when that function returns.
CLEANUP=(stop_lab)
cleanup() {
  # One failing step must not skip the rest.
  setopt localoptions noerrexit
  local step
  for step in "${CLEANUP[@]}"; do "$step"; done
  return 0
}
trap cleanup EXIT
# A trapped signal does not end the script by itself; exiting runs the
# EXIT trap. 128 + the signal number, as an untrapped one would report.
trap 'exit 130' INT
trap 'exit 143' TERM

FMVT_VERSION="$(sed -n 's/^version: *//p' "$REPO_DIR/pubspec.yaml")"
GIT_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"

# The --dart-define flags every build gets, as the array DEFINES.
#   set_defines <device label>
set_defines() {
  DEFINES=(
    "--dart-define=LAB=$LAB"
    "--dart-define=FMVT_VERSION=$FMVT_VERSION"
    "--dart-define=GIT_SHA=$GIT_SHA"
    "--dart-define=DEVICE=$1"
  )
}

# Generates the missing platform scaffolds, then removes what `flutter
# create` drops that would break the repo's analyzer (see .gitignore).
scaffold() {
  local platform="$1"
  [[ -d "$COMPARE_DIR/$platform" ]] && return
  (cd "$COMPARE_DIR" &&
    flutter create --platforms="$platform" --org dev.fmvt \
      --project-name flutter_map_vector_tiles_compare . >/dev/null &&
    rm -rf analysis_options.yaml test)
  case "$platform" in
    macos)
      # The sandbox blocks outgoing connections, including to the lab.
      for f in "$COMPARE_DIR"/macos/Runner/{DebugProfile,Release}.entitlements; do
        /usr/libexec/PlistBuddy -c \
          'Add :com.apple.security.network.client bool true' "$f" 2>/dev/null || true
      done
      # Xcode 27's lipo takes one architecture per -verify_arch, which
      # breaks Flutter's check of a universal build ("does not contain
      # architectures arm64 x86_64"). One architecture is all a benchmark
      # on this machine needs.
      echo "ARCHS = $(uname -m)" >>"$COMPARE_DIR/macos/Flutter/Flutter-Release.xcconfig"
      # Xcode 27 also refuses the template's 10.15 deployment target.
      sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 10.15/MACOSX_DEPLOYMENT_TARGET = 12.0/g' \
        "$COMPARE_DIR/macos/Runner.xcodeproj/project.pbxproj"
      ;;
    android)
      # The lab is plain HTTP on localhost (via `adb reverse`), which
      # Android refuses by default.
      sed -i '' 's/<application/<application android:usesCleartextTraffic="true"/' \
        "$COMPARE_DIR/android/app/src/main/AndroidManifest.xml"
      grep -q 'android.permission.INTERNET' \
        "$COMPARE_DIR/android/app/src/main/AndroidManifest.xml" ||
        sed -i '' 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' \
          "$COMPARE_DIR/android/app/src/main/AndroidManifest.xml"
      ;;
  esac
}

# Starts the lab server for one session in the background. Refuses a port
# that is already taken: a lab server left over from another session would
# answer in this one's place, and this session's runs would be written into
# that one's results.
#   start_lab <platform> <rounds> [extra lab_server args…]
start_lab() {
  local platform="$1" rounds="$2" log="$COMPARE_DIR/.lab-$1.log" holder
  shift 2
  holder="$(lsof -nP -iTCP:"$LAB_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  if [[ -n "$holder" ]]; then
    echo "port $LAB_PORT is taken by pid $holder" \
      "($(ps -o comm= -p "$holder")); stop it, or set LAB_PORT" >&2
    exit 1
  fi
  # `exec`, so that LAB_PID is the server itself, not a subshell whose
  # death would leave the server running.
  (cd "$COMPARE_DIR" &&
    exec dart run tool/lab_server.dart --port "$LAB_PORT" \
      --platform "$platform" --rounds "$rounds" "$@" >"$log" 2>&1) &
  LAB_PID=$!
  for _ in {1..60}; do
    if ! kill -0 "$LAB_PID" 2>/dev/null; then
      echo "lab server exited:" >&2
      tail -5 "$log" >&2
      exit 1
    fi
    curl -sf "$LAB/_status" >/dev/null 2>&1 && return
    sleep 0.5
  done
  echo "lab server did not start; see $log" >&2
  exit 1
}

# Stops the lab server this script started, if it is still running. Always
# succeeds, so the cleanup steps after it run.
stop_lab() {
  if [[ -n "$LAB_PID" ]] && kill -0 "$LAB_PID" 2>/dev/null; then
    kill "$LAB_PID" 2>/dev/null
  fi
  LAB_PID=
  return 0
}

# True while the queue still has runs that have not finished.
lab_busy() {
  curl -sf "$LAB/_status" | grep -qE '"(pending|running)":\["'
}

# True while the queue has runs nobody has taken yet.
lab_pending() {
  curl -sf "$LAB/_status" | grep -q '"pending":\["'
}

# True while a run is handed out but not finished.
lab_running() {
  curl -sf "$LAB/_status" | grep -q '"running":\["'
}

# The directory the lab wrote this session to, as its first log line names
# it (honours --session and --out). `dart run` prefixes that line with its
# own progress text, hence no anchor.
#   lab_results <platform>
lab_results() {
  LC_ALL=C sed -n 's/.*lab server on .* · results //p' "$COMPARE_DIR/.lab-$1.log" |
    head -1
}
