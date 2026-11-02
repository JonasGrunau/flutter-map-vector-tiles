#!/bin/bash
# Rebuilds the subset Noto fonts the script suite draws with: each one
# instanced to its Regular weight (and normal width) and cut down to the
# characters in ../script_samples.dart, so the whole set stays small.
#
#   test/scripts/fonts/build.sh
#
# Needs fonttools (`pip install fonttools`), dart, curl and network
# access. Sources come from google/fonts at a pinned commit, so a rebuild
# changes a font only when the samples change. Run it after adding a
# sample string, then regenerate the goldens (see ../AGENTS.md).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
commit=e7db6ca603fd4862010383ff17ffd6cc4ffac1c0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd "$root" && dart run test/scripts/fonts/charset.dart) >"$work/charset.txt"

# google/fonts path, then the file name used here. The order is the
# fallback order the suite loads them in (see ../script_harness.dart).
fonts=(
  "ofl/notosans/NotoSans[wdth,wght].ttf NotoSans"
  "ofl/notosansarmenian/NotoSansArmenian[wdth,wght].ttf NotoSansArmenian"
  "ofl/notosansgeorgian/NotoSansGeorgian[wdth,wght].ttf NotoSansGeorgian"
  "ofl/notosanshebrew/NotoSansHebrew[wdth,wght].ttf NotoSansHebrew"
  "ofl/notosansarabic/NotoSansArabic[wdth,wght].ttf NotoSansArabic"
  "ofl/notosansbengali/NotoSansBengali[wdth,wght].ttf NotoSansBengali"
  "ofl/notosanstamil/NotoSansTamil[wdth,wght].ttf NotoSansTamil"
  "ofl/notosanssinhala/NotoSansSinhala[wdth,wght].ttf NotoSansSinhala"
  "ofl/notosansthai/NotoSansThai[wdth,wght].ttf NotoSansThai"
  "ofl/notosanslao/NotoSansLao[wdth,wght].ttf NotoSansLao"
  "ofl/notosanskhmer/NotoSansKhmer[wdth,wght].ttf NotoSansKhmer"
  "ofl/notosansmyanmar/NotoSansMyanmar[wdth,wght].ttf NotoSansMyanmar"
  "ofl/notoseriftibetan/NotoSerifTibetan[wght].ttf NotoSerifTibetan"
  "ofl/notosanssc/NotoSansSC[wght].ttf NotoSansSC"
  "ofl/notosanskr/NotoSansKR[wght].ttf NotoSansKR"
  "ofl/notoemoji/NotoEmoji[wght].ttf NotoEmoji"
)

copyrights=()
i=0
for entry in "${fonts[@]}"; do
  path=${entry% *}
  name=${entry#* }
  url="https://raw.githubusercontent.com/google/fonts/$commit"
  curl -sfL -o "$work/src.ttf" "$url/$(echo "$path" | sed 's/\[/%5B/; s/\]/%5D/')"
  copyrights+=("$name: $(curl -sfL "$url/$(dirname "$path")/OFL.txt" | head -1)")
  axes=(wght=400)
  [[ $path == *wdth* ]] && axes+=(wdth=100)
  fonttools varLib.instancer -q --update-name-table -o "$work/$i.ttf" "$work/src.ttf" "${axes[@]}"
  i=$((i + 1))
done

# Each font keeps only the characters it will draw: those no font
# earlier in the fallback order maps. The invisible joiners, marks and
# isolates stay in the first font, and in another only where a sample
# puts one next to a letter that font draws, so a shaping run is not
# split at them. More is worse, not just bigger: a font that maps a
# joiner but none of the letters around it, ahead of the one that does,
# makes Flutter's family fallback draw those letters as .notdef boxes.
python3 - "$work" "${#fonts[@]}" <<'PY'
import sys
import unicodedata
from fontTools.ttLib import TTFont
work, count = sys.argv[1], int(sys.argv[2])
lines = open(f"{work}/charset.txt", encoding="utf-8").read().rstrip("\n").split("\n")
# Shapers decompose some characters before looking them up (Thai and
# Lao SARA AM always), so the pieces must be mapped too.
wanted = {ord(c) for line in lines for ch in line for c in ch + unicodedata.normalize("NFKD", ch)}
controls = {0x200C, 0x200D, 0x200E, 0x200F, 0x2066, 0x2067, 0x2068, 0x2069, 0xFE0F, 0x25CC}
covered = set()
for i in range(count):
    cmap = set(TTFont(f"{work}/{i}.ttf").getBestCmap())
    drawn = (wanted & cmap) - covered - controls
    covered |= wanted & cmap
    if i == 0:
        kept = controls & cmap
    else:
        kept = {ord(line[k]) for line in lines for k in range(len(line))
                if ord(line[k]) in controls & cmap
                and any(0 <= j < len(line) and ord(line[j]) in drawn for j in (k - 1, k + 1))}
    with open(f"{work}/{i}.txt", "w") as out:
        out.write(",".join(f"U+{c:04X}" for c in sorted(drawn | kept)))
missing = wanted - covered - controls
if missing:
    sys.exit("no font maps " + " ".join(f"U+{c:04X}" for c in sorted(missing)))
PY

i=0
for entry in "${fonts[@]}"; do
  name=${entry#* }
  pyftsubset "$work/$i.ttf" \
    --unicodes-file="$work/$i.txt" \
    --layout-features='*' \
    --notdef-outline \
    --no-hinting \
    --name-IDs='*' \
    --output-file="$here/$name.ttf" 2>&1 | grep -v 'meta NOT subset' || true
  echo "$name.ttf: $(wc -c <"$here/$name.ttf" | tr -d ' ') bytes"
  i=$((i + 1))
done

{
  echo "The fonts in this directory are subsets of the Noto fonts in"
  echo "google/fonts@$commit, used only by the tests in test/scripts/."
  echo
  printf '%s\n' "${copyrights[@]}"
  echo
  curl -sfL "https://raw.githubusercontent.com/google/fonts/$commit/ofl/notosans/OFL.txt" | tail -n +2
} >"$here/OFL.txt"
