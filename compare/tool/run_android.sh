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
ROUNDS="${2:-4}"
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

# Keep the screen on and the orientation fixed for the whole session, and
# put the owner's settings back afterwards. Portrait, because a phone
# turned on its side mid-session changes the tiles per screen for every
# run after it (summarize.dart warns about mixed viewports).
setting() { "${ADB[@]}" shell settings get "$1" "$2" | tr -d '\r'; }
STAY_ON="$(setting global stay_on_while_plugged_in)"
AUTO_ROTATE="$(setting system accelerometer_rotation)"
USER_ROTATION="$(setting system user_rotation)"
# `settings get` prints "null" for a setting that was never set; putting
# that back would store the string "null", so delete it instead.
#   put_back <namespace> <key> <value as read>
put_back() {
  if [[ -z "$3" || "$3" == null ]]; then
    "${ADB[@]}" shell settings delete "$1" "$2" >/dev/null
  else
    "${ADB[@]}" shell settings put "$1" "$2" "$3"
  fi
}
restore() {
  put_back global stay_on_while_plugged_in "$STAY_ON"
  put_back system user_rotation "$USER_ROTATION"
  put_back system accelerometer_rotation "$AUTO_ROTATE"
  "${ADB[@]}" reverse --remove "tcp:$LAB_PORT" >/dev/null 2>&1
  return 0
}
# From here on every way out puts them back (common.sh's traps).
CLEANUP+=(restore)
"${ADB[@]}" reverse "tcp:$LAB_PORT" "tcp:$LAB_PORT" >/dev/null
"${ADB[@]}" shell settings put global stay_on_while_plugged_in 15
"${ADB[@]}" shell settings put system accelerometer_rotation 0
"${ADB[@]}" shell settings put system user_rotation 0

start_lab android "$ROUNDS" "$@"
while lab_busy; do
  # The app takes the next queued run, measures it and exits; Android may
  # relaunch it on its own, in which case it simply takes the next run. An
  # app that crashes leaves its run `running` until the lab server gives
  # it up (--run-timeout), and then this launches the next one.
  if ! lab_running && ! "${ADB[@]}" shell pidof "$PKG" >/dev/null; then
    # Stay-on keeps a lit screen lit, but does not light a dark one: a
    # screen that went off before the session (or between two of them)
    # leaves the app paused and the run waiting forever. Without a PIN this
    # also dismisses the lock screen; with one, unlock the phone yourself.
    "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
    "${ADB[@]}" shell wm dismiss-keyguard
    "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
  fi
  sleep 3
done
echo "results: $(lab_results android)"
