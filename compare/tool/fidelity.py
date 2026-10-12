#!/usr/bin/env python3
"""Turns a session's raw screenshots into the WebP grid in RESULTS.md.

    python3 -I tool/fidelity.py results/raw/<session> [--width 900]

Writes results/shots/<session>/<camera>-<arm>.webp and prints the Markdown
table, one row per camera, MapLibre's reference first when the session has
it (tool/reference_shots.mjs writes it into the same shots directory).
Needs Pillow with WebP support.
"""
import argparse
import os
import sys

from PIL import Image

ARMS = ['maplibre', 'fmvt', 'fmvt-raster', 'vmt-raster', 'vmt-vector',
        'fmvt-none', 'fmvt-raster-none']
TITLES = {
    'maplibre': 'MapLibre GL JS (reference)',
    'fmvt': 'flutter_map_vector_tiles',
    'fmvt-raster': 'flutter_map_vector_tiles · LabelMode.tile',
    'fmvt-raster-none':
        'flutter_map_vector_tiles · LabelMode.tile · TileOffset.none',
    'vmt-raster': 'vector_map_tiles · raster',
    'vmt-vector': 'vector_map_tiles · vector',
    'fmvt-none': 'flutter_map_vector_tiles · TileOffset.none',
}
CAMERAS = ['munich-z14', 'munich-z16', 'munich-z16-rot45', 'munich-z17.5', 'munich-z18']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('session')
    parser.add_argument('--width', type=int, default=900)
    parser.add_argument('--arms',
                        default='maplibre,fmvt,fmvt-raster,vmt-raster,vmt-vector')
    args = parser.parse_args()

    session = os.path.basename(os.path.normpath(args.session))
    raw = os.path.join(args.session, 'shots')
    out = os.path.join('results', 'shots', session)
    os.makedirs(out, exist_ok=True)
    arms = args.arms.split(',')

    def source(arm, camera):
        if arm == 'maplibre':
            return os.path.join(raw, f'maplibre-{camera}.png')
        matches = [f for f in os.listdir(raw) if f.endswith(f'-{arm}-{camera}.png')]
        return os.path.join(raw, matches[0]) if matches else None

    present = [a for a in arms if any(
        (p := source(a, c)) and os.path.exists(p) for c in CAMERAS)]
    rows = []
    for camera in CAMERAS:
        cells = []
        for arm in present:
            path = source(arm, camera)
            if not path or not os.path.exists(path):
                cells.append('–')
                continue
            image = Image.open(path).convert('RGB')
            height = round(image.height * args.width / image.width)
            name = f'{camera}-{arm}.webp'
            image.resize((args.width, height), Image.LANCZOS).save(
                os.path.join(out, name), 'WEBP', quality=82, method=6)
            cells.append(f'[![{TITLES[arm]}, {camera}](results/shots/{session}/{name})]'
                         f'(results/shots/{session}/{name})')
        rows.append(f'| `{camera}` | ' + ' | '.join(cells) + ' |')

    print('| camera | ' + ' | '.join(TITLES[a] for a in present) + ' |')
    print('|---|' + '|'.join(':---:' for _ in present) + '|')
    print('\n'.join(rows))


if __name__ == '__main__':
    sys.exit(main())
