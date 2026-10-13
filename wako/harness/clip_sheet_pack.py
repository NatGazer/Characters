"""Re-tile clip_sheet.py PNGs (4 cols of 640x360 + 2 px pad) into compact JPEG sheets for the repo.

Usage: python3 harness/clip_sheet_pack.py <png_sheet_dir> <jpg_out_dir>"""
import sys, os, glob
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
cols, scale, q = 6, 0.45, 76
os.makedirs(dst, exist_ok=True)
for p in sorted(glob.glob(os.path.join(src, "*.png"))):
    im = Image.open(p).convert("RGB")
    TW, TH, PAD = 640, 360, 2
    ncol = (im.size[0] + PAD) // (TW + PAD)
    nrow = (im.size[1] + PAD) // (TH + PAD)
    tiles = []
    for r in range(nrow):
        for c in range(ncol):
            t = im.crop((c * (TW + PAD), r * (TH + PAD), c * (TW + PAD) + TW, r * (TH + PAD) + TH))
            if t.getbbox() is None or max(t.convert("L").getextrema()) < 8:
                continue                                    # black filler tile
            tiles.append(t.resize((int(TW * scale), int(TH * scale)), Image.LANCZOS))
    w, h = tiles[0].size
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new("RGB", (cols * w + (cols - 1) * 2, rows * h + (rows - 1) * 2))
    for n, t in enumerate(tiles):
        out.paste(t, ((n % cols) * (w + 2), (n // cols) * (h + 2)))
    o = os.path.join(dst, os.path.basename(p)[:-4] + ".jpg")
    out.save(o, quality=q, optimize=True)
    print(o, out.size, os.path.getsize(o) // 1024, "KB", len(tiles), "tiles")
