#!/bin/zsh
# Samples the compare app's GPU memory on an Android device every ~3 s
# while the lab server reports a run in progress, one line per sample:
#
#   tool/gpu_sampler.sh <out file> <adb serial>
#
# run_android.sh starts it for every session, into the session directory,
# so every Android session carries this load the same way. RSS on Android
# leaves out GPU memory, where the tile images live: the figure is the
# `Proc <pid> total:` line of `dumpsys gpu --gpumem`, next to the PSS from
# `dumpsys meminfo`. Spikes shorter than the interval can be missed.
# tool/gpu_memory.py turns the samples into the table in RESULTS.md. Exits
# about 5 min after the lab server stops answering.
OUT="${1:?usage: gpu_sampler.sh <out file> <adb serial>}"
SERIAL="${2:?usage: gpu_sampler.sh <out file> <adb serial>}"
ADB=("${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}" -s "$SERIAL")
LAB="http://localhost:${LAB_PORT:-8790}"
PKG=dev.fmvt.flutter_map_vector_tiles_compare

print -r -- "# GPU memory samples: \`dumpsys gpu --gpumem\`, \`Proc <pid> total:\`, MiB; pssMB from \`dumpsys meminfo\`; every ~3 s while a run is in progress." >"$OUT"
idle=0
while true; do
  st="$(curl -sf "$LAB/_status")"
  if [[ -z "$st" ]]; then
    (( ++idle > 100 )) && exit 0
    sleep 3
    continue
  fi
  idle=0
  run="$(print -r -- "$st" | sed -n 's/.*"running":\["\([^"]*\)".*/\1/p')"
  pid="$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')"
  if [[ -n "$run" && -n "$pid" ]]; then
    bytes="$("${ADB[@]}" shell dumpsys gpu --gpumem | tr -d '\r' |
      sed -n "s/.*Proc $pid total: *\([0-9]*\).*/\1/p" | head -1)"
    pss="$("${ADB[@]}" shell dumpsys meminfo "$pid" | tr -d '\r' |
      sed -n 's/.*TOTAL PSS: *\([0-9]*\).*/\1/p' | head -1)"
    [[ -n "$bytes" ]] && print -r -- "$(date +%H:%M:%S) run=$run gpuMB=$(( bytes / 1048576 )) pssMB=$(( ${pss:-0} / 1024 ))" >>"$OUT"
  fi
  sleep 3
done
