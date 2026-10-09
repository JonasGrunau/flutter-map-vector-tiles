#!/bin/zsh
# Measures every arm on this Mac, each in a fresh process.
#
#   tool/run_macos.sh [rounds] [extra lab_server args, e.g. --scenarios zoom]
#
# Close other apps first; keep the window in front and the Mac on power.
set -e
source "${0:A:h}/common.sh"
ROUNDS="${1:-3}"
(( $# )) && shift

scaffold macos
set_defines "$(sysctl -n hw.model) · macOS $(sw_vers -productVersion)"
cd "$COMPARE_DIR"
flutter build macos --profile "${DEFINES[@]}"
APP="$COMPARE_DIR/build/macos/Build/Products/Profile/flutter_map_vector_tiles_compare.app"

start_lab macos "$ROUNDS" "$@"
trap stop_lab EXIT
while lab_busy; do
  # The app takes the next queued run, measures it and quits.
  open -W -n "$APP"
done
echo "results: $(ls -dt "$COMPARE_DIR"/results/raw/*-macos | head -1)"
