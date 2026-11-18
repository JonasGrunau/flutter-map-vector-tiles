"""Puts a 1206x2622 capture into Apple's iPhone 17 bezel.

    python3 -I frame.py <bezel.png> <capture.png> <framed.webp>

The bezel is `PNG/iPhone 17/iPhone 17 - Black - Portrait.png` from Apple's
product bezels (see ../AGENTS.md). Its screen is a transparent squircle:
the capture is clipped to exactly that region, found by flood-filling the
bezel's alpha from the image centre, so nothing pokes out past the shell's
rounded corners.
"""
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

bezel_path, capture_path, out_path = sys.argv[1:4]
bezel = Image.open(bezel_path).convert('RGBA')
capture = Image.open(capture_path).convert('RGBA')
alpha = bezel.getchannel('A')

# The screen: everything connected to the centre that the bezel leaves
# see-through. The filled value (128) marks it.
seed = alpha.point(lambda a: 255 if a > 0 else 0)
ImageDraw.floodfill(seed, (bezel.width // 2, bezel.height // 2), 128)
screen = seed.point(lambda v: 255 if v == 128 else 0)
left, top, right, bottom = screen.getbbox()
if (right - left, bottom - top) != capture.size:
    capture = capture.resize((right - left, bottom - top), Image.LANCZOS)

# The bezel's inner edge is antialiased: the map has to reach under those
# partly opaque pixels, or a transparent hairline shows between screen and
# shell. So the clip is the screen grown by two pixels, and the bezel is
# composited on top of it.
clip = screen.filter(ImageFilter.MaxFilter(5))

framed = Image.new('RGBA', bezel.size, (0, 0, 0, 0))
layer = Image.new('RGBA', bezel.size, (0, 0, 0, 0))
layer.paste(capture, (left, top))
framed.paste(layer, (0, 0), clip)
framed.alpha_composite(bezel)

with tempfile.NamedTemporaryFile(suffix='.png') as png:
    framed.save(png.name)
    subprocess.run(['cwebp', '-quiet', '-q', '82', '-m', '6', png.name, '-o', out_path],
                   check=True)
print(f'{out_path}: screen {right - left}x{bottom - top} at ({left}, {top})')
