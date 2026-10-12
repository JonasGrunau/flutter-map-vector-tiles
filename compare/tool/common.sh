# Shared by the run scripts: build metadata, scaffolds, and the lab server.
# Sourced, not executed.

COMPARE_DIR="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
REPO_DIR="$(cd "$COMPARE_DIR/.." && pwd)"
LAB_PORT="${LAB_PORT:-8790}"
LAB="http://localhost:$LAB_PORT"

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

# Starts the lab server for one session in the background.
#   start_lab <platform> <rounds> [extra lab_server args…]
start_lab() {
  local platform="$1" rounds="$2"
  shift 2
  (cd "$COMPARE_DIR" &&
    dart run tool/lab_server.dart --port "$LAB_PORT" \
      --platform "$platform" --rounds "$rounds" "$@" \
      >"$COMPARE_DIR/.lab-$platform.log" 2>&1) &
  LAB_PID=$!
  for _ in {1..60}; do
    curl -sf "$LAB/_status" >/dev/null 2>&1 && return
    sleep 0.5
  done
  echo "lab server did not start; see $COMPARE_DIR/.lab-$platform.log" >&2
  exit 1
}

stop_lab() {
  [[ -n "$LAB_PID" ]] && kill "$LAB_PID" 2>/dev/null
}

# True while the queue still has runs that have not finished.
lab_busy() {
  curl -sf "$LAB/_status" | grep -qE '"(pending|running)":\["'
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
