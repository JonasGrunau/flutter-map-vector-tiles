#!/bin/zsh
# Measures every arm in Chrome (headed, so the GPU is real), each in a fresh
# browser context.
#
#   tool/run_web.sh [rounds] [--wasm] [extra lab_server args]
#
# Needs Node; installs Playwright into tool/node_modules on first use and
# drives the Chrome installed on this machine.
set -e
source "${0:A:h}/common.sh"
ROUNDS="${1:-3}"
(( $# )) && shift
WASM=()
PLATFORM=web
if [[ "$1" == "--wasm" ]]; then
  WASM=(--wasm)
  PLATFORM=web-wasm
  shift
fi

set_defines "Chrome · $(sysctl -n hw.model) · macOS $(sw_vers -productVersion)"
cd "$COMPARE_DIR"
flutter build web --profile --base-href /app/ "${WASM[@]}" "${DEFINES[@]}"
[[ -d tool/node_modules/playwright ]] ||
  (cd tool && npm install --no-save --silent playwright@1.49.1)

start_lab "$PLATFORM" "$ROUNDS" --app build/web "$@"
trap stop_lab EXIT
node tool/run_web.mjs "$LAB"
echo "results: $(lab_results "$PLATFORM")"
