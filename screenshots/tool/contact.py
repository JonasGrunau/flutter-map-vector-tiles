"""Contact sheet of the raw captures in out/, for reviewing them at a glance.

    python3 -I contact.py            # writes out/contact.png
"""
import glob
import os
from PIL import Image, ImageDraw

here = os.path.dirname(os.path.abspath(__file__))
files = sorted(f for f in glob.glob(os.path.join(here, 'out', '*.png'))
               if not f.endswith('contact.png'))
cell_w, cell_h, pad, cols = 560, 380, 16, 3
rows = -(-len(files) // cols)
sheet = Image.new('RGB', (cols * (cell_w + pad) + pad, rows * (cell_h + pad) + pad), 'white')
draw = ImageDraw.Draw(sheet)
for i, path in enumerate(files):
    image = Image.open(path).convert('RGB')
    image.thumbnail((cell_w, cell_h - 24))
    x = pad + (i % cols) * (cell_w + pad)
    y = pad + (i // cols) * (cell_h + pad)
    sheet.paste(image, (x, y + 24))
    draw.text((x, y + 4), os.path.basename(path), fill='black')
sheet.save(os.path.join(here, 'out', 'contact.png'))
