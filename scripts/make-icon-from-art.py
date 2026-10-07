#!/usr/bin/env python3
"""Hazır bir ikon çiziminden (AI çıktısı vb.) macOS AppIcon setini üretir.

    python3 scripts/make-icon-from-art.py App/Resources/Brand/icon-source-gemini.jpg [--preview out.png]

Çizimdeki koyu kareyi bulur, kenar artıklarını kırpar, Apple'ın 1024 ızgarasına
(824 pt kare, 100 pt boşluk) yerleştirir, macOS sürekli köşe maskesi ve yumuşak
gölge uygular, 16–1024 px tüm boyutları yazar. Kaynak: TASARIM.md §Uygulama ikonu.
"""
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), '..')
OUT_DIR = os.path.join(ROOT, 'App/Resources/Assets.xcassets/AppIcon.appiconset')
SS = 4  # supersampling


def continuous_mask(size):
    """macOS icon shape: rounded square, corner radius 22.37% of the side
    (Apple's Big Sur+ template). Drawn at the supersampled size, so the
    final downscale yields smooth, continuous-looking corners."""
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=round(size * 0.2237), fill=255)
    return m


def build(src_path):
    src = Image.open(src_path).convert('RGB')
    dark = src.convert('L').point(lambda v: 255 if v < 110 else 0)
    x0, y0, x1, y1 = dark.getbbox()
    side = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    inset = int(side * 0.035)  # drop the AI's own rounded corners & rim
    art = src.crop((cx - side // 2 + inset, cy - side // 2 + inset, cx + side // 2 - inset, cy + side // 2 - inset))

    S = 1024 * SS
    tile = 824 * SS
    off = (S - tile) // 2
    art = art.resize((tile, tile), Image.LANCZOS).convert('RGBA')
    mask = continuous_mask(tile)
    art.putalpha(mask)

    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh = Image.new('L', (S, S), 0)
    sh.paste(mask, (off, off + 10 * SS))
    sh = sh.filter(ImageFilter.GaussianBlur(22 * SS)).point(lambda v: int(v * 0.40))
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 255))
    shadow.putalpha(sh)
    out = Image.alpha_composite(out, shadow)
    out.alpha_composite(art, (off, off))
    # Hairline highlight along the top edge, like system icons.
    from PIL import ImageChops
    ring = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(5)))
    fade = Image.linear_gradient('L').resize((tile, tile)).point(lambda v: int((255 - v) * 0.10))
    hl = Image.new('RGBA', (tile, tile), (255, 255, 255, 255))
    hl.putalpha(ImageChops.multiply(ring, fade))
    out.alpha_composite(hl, (off, off))
    return out.resize((1024, 1024), Image.LANCZOS)


def main():
    src = sys.argv[1]
    icon = build(src)
    if '--preview' in sys.argv:
        icon.save(sys.argv[sys.argv.index('--preview') + 1]); return
    os.makedirs(OUT_DIR, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f'icon_{pt}x{pt}{"@2x" if scale == 2 else ""}.png'
            img = icon.resize((px, px), Image.LANCZOS)
            if px <= 64:  # tiny sizes: a touch of sharpening
                img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
            img.save(os.path.join(OUT_DIR, name))
            images.append({'idiom': 'mac', 'size': f'{pt}x{pt}', 'scale': f'{scale}x', 'filename': name})
    json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}},
              open(os.path.join(OUT_DIR, 'Contents.json'), 'w'), indent=2, sort_keys=True)
    print('AppIcon yazıldı:', OUT_DIR)


if __name__ == '__main__':
    main()
