"""Regenerate the Windows icon from assets/logo.svg.

Development-only dependencies: Pillow and resvg-py==0.5.0.
Run from any directory: python windows/scripts/Generate-AppIcon.py
No image-generation dependencies are needed by the build or installer.
"""

from io import BytesIO
from pathlib import Path

from PIL import Image
import resvg_py


def main():
    root = Path(__file__).resolve().parents[2]
    png = resvg_py.svg_to_bytes(
        svg_path=str(root / "assets/logo.svg"),
        width=256,
        height=256,
        skip_system_fonts=True,
    )
    image = Image.open(BytesIO(png)).convert("RGBA")
    image.save(
        root / "assets/caelestia.ico",
        sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)],
    )


if __name__ == "__main__":
    main()
