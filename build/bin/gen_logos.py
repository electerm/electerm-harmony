#!/usr/bin/env python3
"""
Generate HarmonyOS app icons (entry/src/main/resources/base/media/*)
 from the source logos in build/logos.

Currently the square logo is resized to 1024x1024 RGBA and written as
 both `app_icon.png` and `start_icon.png`, which are the icons referenced
 by entry/src/main/module.json5 (`$media:app_icon`).

Requirements:
  - Python 3.7+
  - Pillow  (pip install Pillow)

Usage:
  python3 build/bin/gen_logos.py
"""

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit(
        'Pillow is required. Install it with:  pip install Pillow'
    )

# Project root is two levels up from this script (build/bin -> build -> root)
ROOT = Path(__file__).resolve().parent.parent.parent

# Source logo (square, high-resolution)
SOURCE = ROOT / 'build' / 'logos' / 'electerm-logo-square.png'

# Output directory for HarmonyOS media resources
MEDIA_DIR = ROOT / 'entry' / 'src' / 'main' / 'resources' / 'base' / 'media'

# Target icon size (HarmonyOS expects 1024x1024 app icons)
ICON_SIZE = (1024, 1024)

# Output file names generated from the square logo
OUTPUTS = ['app_icon.png', 'start_icon.png']


def main() -> int:
    if not SOURCE.exists():
        print(f'error: source logo not found: {SOURCE}', file=sys.stderr)
        return 1

    MEDIA_DIR.mkdir(parents=True, exist_ok=True)

    print(f'gen_logos: opening {SOURCE.relative_to(ROOT)}')
    with Image.open(SOURCE) as img:
        print(f'  source size: {img.size}  mode: {img.mode}')

        # Resize to the target icon size with high-quality resampling
        resized = img.resize(ICON_SIZE, Image.LANCZOS)

        # HarmonyOS icons are expected to be RGBA
        if resized.mode != 'RGBA':
            resized = resized.convert('RGBA')

        for name in OUTPUTS:
            out_path = MEDIA_DIR / name
            resized.save(out_path, 'PNG')
            print(f'  wrote {out_path.relative_to(ROOT)}  '
                  f'{resized.size}  {resized.mode}')

    print('gen_logos: done')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
