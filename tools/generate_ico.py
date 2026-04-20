"""Generate a multi-resolution Windows .ico from a square PNG.

Usage:
    python tools/generate_ico.py <input.png> <output.ico>

Produces an ICO with the standard Windows sizes 16, 24, 32, 40, 48, 64, 96,
128 and 256 px, so Windows can pick the right one for taskbar, titlebar,
explorer thumbnails and alt-tab without ugly runtime down-scaling.
"""
import sys
from PIL import Image

SIZES = [16, 24, 32, 40, 48, 64, 96, 128, 256]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]

    img = Image.open(src).convert("RGBA")
    # Pillow's save() with format="ICO" accepts a `sizes` list and internally
    # creates a proper multi-image ICO using high-quality LANCZOS resampling.
    img.save(dst, format="ICO", sizes=[(s, s) for s in SIZES])
    print(f"Wrote {dst} with sizes: {SIZES}")


if __name__ == "__main__":
    main()
