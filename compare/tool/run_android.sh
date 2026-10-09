#!/bin/zsh
# Measures every arm on an Android device over USB, each in a fresh process.
#
#   tool/run_android.sh <adb serial> [rounds] [extra lab_server args]
#
# The device reaches the lab server through `adb reverse`, so tiles come
# over USB, not Wi-Fi.
set -e
source "${0:A:h}/common.sh"
SERIAL="${1:?usage: run_android.sh <adb serial> [rounds] [lab_server args]}"
ROUNDS="${2:-3}"
shift
(( $# )) && shift
ADB=("${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}" -s "$SERIAL")
PKG=dev.fmvt.flutter_map_vector_tiles_compare
prop() { "${ADB[@]}" shell getprop "$1" | tr -d '\r'; }

scaffold android
set_defines "$(prop ro.product.manufacturer) $(prop ro.product.model) · Android $(prop ro.build.version.release)"
cd "$COMPARE_DIR"
flutter build apk --profile "${DEFINES[@]}"
"${ADB[@]}" install -r build/app/outputs/flutter-apk/app-profile.apk >/dev/null
"${ADB[@]}" reverse "tcp:$LAB_PORT" "tcp:$LAB_PORT" >/dev/null
"${ADB[@]}" shell svc power stayon true

start_lab android "$ROUNDS" "$@"
trap 'stop_lab; "${ADB[@]}" shell svc power stayon false' EXIT
while lab_busy; do
  # The app takes the next queued run, measures it and exits; Android may
  # relaunch it on its own, in which case it simply takes the next run.
  if ! lab_running && ! "${ADB[@]}" shell pidof "$PKG" >/dev/null; then
    "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
  fi
  sleep 3
done
echo "results: $(ls -dt "$COMPARE_DIR"/results/raw/*-android | head -1)"
