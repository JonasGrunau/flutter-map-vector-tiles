#!/usr/bin/env python3
"""Turns tool/gpu_sampler.sh's samples into the GPU table in RESULTS.md.

    python3 -I tool/gpu_memory.py results/raw/<session>/gpu-memory.txt

Prints each run's peak, then one Markdown row: per arm, the median of its
runs' peaks with their range, in the arm order of the other tables.
"""
import collections
import re
import statistics
import sys

ARMS = ['fmvt', 'fmvt-none', 'fmvt-raster', 'fmvt-raster-none',
        'vmt-raster', 'vmt-vector']

runs = collections.defaultdict(list)
for line in open(sys.argv[1]):
    m = re.search(r'run=(\S+) gpuMB=(\d+) pssMB=(\d+)', line)
    if m:
        runs[m[1]].append((int(m[2]), int(m[3])))

peaks = collections.defaultdict(list)
for run, samples in sorted(runs.items()):
    # Run ids are <platform>-r<round>-<arm>.
    arm = run.split('-', 2)[2]
    gpu = [g for g, _ in samples]
    peaks[arm].append(max(gpu))
    print(f'{run:32} {len(samples):3} samples  GPU peak {max(gpu):4} MB, '
          f'median {statistics.median(gpu):6.1f}  '
          f'PSS peak {max(p for _, p in samples):4} MB')

arms = [a for a in ARMS if a in peaks] + sorted(set(peaks) - set(ARMS))
print()
print('| | ' + ' | '.join(arms) + ' |')
print('|---|' + '---:|' * len(arms))
print('| peak GPU allocation | ' + ' | '.join(
    f'{statistics.median(peaks[a]):.0f} '
    f'<sub>{min(peaks[a])}–{max(peaks[a])}</sub>' for a in arms) + ' |')
