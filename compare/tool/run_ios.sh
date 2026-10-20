#!/bin/zsh
# Measures every arm on an iPhone over USB, each in a fresh process.
#
#   IOS_TEAM=<team id> tool/run_ios.sh <udid> [rounds] [extra lab_server args]
#
# `xcrun devicectl list devices` prints the UDID. IOS_TEAM, the team that
# signs the app, is only read when the scaffold is generated (`security
# find-identity -v -p codesigning` lists the teams in brackets).
#
# iOS has no `adb reverse`. A wired iPhone is also a network link, though:
# the Mac shows it as a "USB Ethernet" interface with a link-local address,
# and the app reaches the lab server there, so tiles still come over USB,
# not Wi-Fi. LAB_HOST overrides the address (one interface per cable; set
# it when two devices are plugged in). The first launch asks to find
# devices on the local network: unlock the phone and tap Allow, once.
set -e
source "${0:A:h}/common.sh"
UDID="${1:?usage: IOS_TEAM=<team> run_ios.sh <udid> [rounds] [lab_server args]}"
ROUNDS="${2:-4}"
shift
(( $# )) && shift
BUNDLE=dev.fmvt.flutterMapVectorTilesCompare
APP_LOG="$COMPARE_DIR/.lab-ios-app.log"

if [[ ! -d "$COMPARE_DIR/ios" && -z "$IOS_TEAM" ]]; then
  echo "set IOS_TEAM to the team that signs the app; the teams here:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

# The Mac's end of the USB link: an interface of type "USB Ethernet" with
# a 169.254 address. Wi-Fi would also work, but would put a radio between
# the packages and their tiles.
if [[ -z "$LAB_HOST" ]]; then
  links=()
  for ifc in $(ifconfig -l); do
    ifconfig -v "$ifc" 2>/dev/null | grep -q 'type: USB Ethernet' || continue
    addr="$(ifconfig "$ifc" | sed -n 's/.*inet \(169\.254\.[0-9.]*\).*/\1/p')"
    [[ -n "$addr" ]] && links+=("$addr")
  done
  if (( ${#links} != 1 )); then
    echo "found ${#links} USB network links (${links[*]}); set LAB_HOST" \
      "to the Mac's address on the iPhone's" >&2
    exit 1
  fi
  LAB_HOST="${links[1]}"
fi

DETAILS="$(mktemp -t fmvt-ios)"
xcrun devicectl device info details --device "$UDID" --quiet \
  --json-output "$DETAILS" >/dev/null
MODEL="$(python3 -c 'import json,sys
r = json.load(open(sys.argv[1]))["result"]
print(r["hardwareProperties"]["marketingName"], "· iOS",
      r["deviceProperties"]["osVersionNumber"])' "$DETAILS")"
rm -f "$DETAILS"

scaffold ios
set_defines "$MODEL"
# The phone cannot reach the Mac's localhost; everything else here can.
DEFINES[1]="--dart-define=LAB=http://$LAB_HOST:$LAB_PORT"
cd "$COMPARE_DIR"
flutter build ios --profile "${DEFINES[@]}"
xcrun devicectl device install app --device "$UDID" --quiet \
  build/ios/iphoneos/Runner.app

# devicectl forwards the signals it catches to the app it launched, so
# interrupting it ends a run that would otherwise keep the screen lit.
APP_PID=
stop_app() {
  [[ -n "$APP_PID" ]] && kill -INT "$APP_PID" 2>/dev/null
  APP_PID=
  return 0
}
CLEANUP+=(stop_app)

start_lab ios "$ROUNDS" --bind "$LAB_HOST" "$@"
: >"$APP_LOG"
while lab_busy; do
  if lab_pending; then
    # The app takes the next queued run, measures it and exits; --console
    # waits for that. In the background with `wait`, so that a signal to
    # this script is handled now, not after the run.
    xcrun devicectl device process launch --device "$UDID" --console \
      "$BUNDLE" >>"$APP_LOG" 2>&1 &
    APP_PID=$!
    if ! wait "$APP_PID"; then
      # Also what a locked phone looks like: iOS launches nothing until it
      # is unlocked.
      echo "launch failed or the app crashed (phone locked?); see $APP_LOG" >&2
      sleep 10
    fi
    APP_PID=
  else
    # Only a run whose app crashed is left; the lab server gives it up
    # after --run-timeout. A new app would find nothing to run.
    sleep 3
  fi
done
echo "results: $(lab_results ios)"
