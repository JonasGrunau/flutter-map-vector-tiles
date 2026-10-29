"""Subsets OpenFreeMap's Noto Sans Regular glyph PBFs to the characters
the glyph-drawn script samples use. Usage: subset.py <out dir> <text...>"""
import sys, urllib.request
out = sys.argv[1]
chars = sorted(set(''.join(sys.argv[2:])) | {' '})
def varint(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r, i
def fields(b):
    i = 0
    while i < len(b):
        t, j = varint(b, i); f, w = t >> 3, t & 7
        if w == 0: _, k = varint(b, j)
        elif w == 2:
            l, k = varint(b, j); k += l
        elif w == 5: k = j + 4
        elif w == 1: k = j + 8
        yield f, w, b[i:k], b
        i = k
def payload(raw):
    t, j = varint(raw, 0); l, k = varint(raw, j); return raw[k:]
def enc_varint(v):
    o = bytearray()
    while v >= 0x80: o.append(v & 0x7f | 0x80); v >>= 7
    o.append(v); return bytes(o)
ranges = {}
for c in chars: ranges.setdefault(ord(c) // 256 * 256, set()).add(ord(c))
for start, want in sorted(ranges.items()):
    url = f'https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/{start}-{start+255}.pbf'
    data = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'flutter_map_vector_tiles-tests/0.1'})).read()
    for f, w, raw, _ in fields(data):
        stack = payload(raw)
        kept = bytearray(); found = set()
        for f2, w2, raw2, _ in fields(stack):
            if f2 != 3: kept += raw2; continue
            g = payload(raw2)
            gid = None
            for f3, w3, raw3, _ in fields(g):
                if f3 == 1: gid, _ = varint(raw3, 1)
            if gid in want: kept += raw2; found.add(gid)
        missing = want - found
        if missing: print('missing', start, [chr(m) for m in missing])
        body = b'\x0a' + enc_varint(len(kept)) + bytes(kept)
        open(f'{out}/{start}-{start+255}.pbf', 'wb').write(body)
        print(start, len(found), len(body))
