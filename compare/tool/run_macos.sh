#!/bin/zsh
# Measures every arm on this Mac, each in a fresh process.
#
#   tool/run_macos.sh [rounds] [extra lab_server args, e.g. --scenarios zoom]
#
# Close other apps first; keep the window in front and the Mac on power.
set -e
source "${0:A:h}/common.sh"
ROUNDS="${1:-4}"
(( $# )) && shift

scaffold macos
set_defines "$(sysctl -n hw.model) · macOS $(sw_vers -productVersion)"
cd "$COMPARE_DIR"
flutter build macos --profile "${DEFINES[@]}"
APP="$COMPARE_DIR/build/macos/Build/Products/Profile/flutter_map_vector_tiles_compare.app"

start_lab macos "$ROUNDS" "$@"
while lab_busy; do
  if lab_pending; then
    # The app takes the next queued run, measures it and quits.
    open -W -n "$APP"
  else
    # Only a run whose app crashed is left; the lab server gives it up
    # after --run-timeout. A new app would find nothing to run.
    sleep 3
  fi
done
echo "results: $(lab_results macos)"
