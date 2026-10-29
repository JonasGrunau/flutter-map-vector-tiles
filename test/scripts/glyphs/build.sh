#!/bin/sh
# Rebuilds the glyph PBF subsets in this directory from OpenFreeMap's
# Noto Sans Regular glyph ranges (Noto: SIL Open Font License, see
# ../fonts/OFL.txt). Each range keeps only the characters of the
# glyph-drawn samples in script_glyphs_test.dart, plus ASCII letters and
# digits. Needs python3 and network; run from this directory.
set -e
cd "$(dirname "$0")"
python3 -I subset.py . \
  'Đà Nẵng' 'Bãi biển Mỹ Khê Đà Nẵng' 'Ærø Øresund' 'Øresundsbroen Ærø Færøerne' \
  'Śląsk' 'Województwo śląskie Łódź' 'Москва' 'Улица Большая Морская' \
  'Αθήνα' 'Οδός Ερμού Θεσσαλονίκη' 'Երևան' 'Մաշտոցի պողոտա Երևան' \
  'თბილისი' 'რუსთაველის გამზირი თბილისი' 'Café' \
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
