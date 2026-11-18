#!/bin/sh
# Regenerates the screenshots: builds `shot_app.dart` for the web, captures
# every shot in headless Chrome and frames the phone ones.
#
#     ./capture.sh [shot name ...]
#     BEZEL="/path/to/iPhone 17 - Black - Portrait.png" ./capture.sh
#
# Needs Google Chrome, node, cwebp and python3 with Pillow. Without BEZEL
# the phone shots stay unframed in out/. See ../AGENTS.md.
set -e
cd "$(dirname "$0")"

(cd ../../example && flutter build web --release -t ../screenshots/tool/shot_app.dart)
[ -d node_modules/playwright ] || npm install --no-save playwright@1.49.1
node capture.mjs "$@"

if [ -n "$BEZEL" ]; then
  for shot in buildings-3d; do
    [ -f "out/$shot.png" ] &&
      python3 -I frame.py "$BEZEL" "out/$shot.png" "../$shot-framed.webp"
  done
fi
python3 -I contact.py
