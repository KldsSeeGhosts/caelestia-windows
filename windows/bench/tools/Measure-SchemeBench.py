"""Exercise the real scheme helper, never the live wallpaper/profile."""
import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import random
import sys
import time

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser(__doc__)
parser.add_argument("--source", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--plant", action="store_true")
args = parser.parse_args()
root = Path(args.output).resolve()
root.mkdir(exist_ok=True)
os.environ["CAELESTIA_PROFILE_ROOT"] = str(root / "profile")
source = Path(args.source) / "windows/scripts/scheme/win_scheme.py"
spec = importlib.util.spec_from_file_location("bench_scheme", source)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
from PIL import Image, ImageDraw

image = Image.new("RGB", (2400, 1600), (24, 32, 48))
draw = ImageDraw.Draw(image)
rng = random.Random(7)
for _ in range(24):
    x, y = rng.randrange(2400), rng.randrange(1600)
    radius = rng.randrange(120, 480)
    colour = tuple(rng.randrange(256) for _ in range(3))
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=colour)
wallpaper = root / "synthetic.jpg"
image.save(wallpaper, "JPEG", quality=90)
values, work = {}, []
for name in ("scheme.wallpaperApplyMs",):
    extra_count, extra_ns, extra_checksums = 0, 0, []
    start = time.perf_counter_ns()
    result = helper.apply_wallpaper(wallpaper, None, None, None, True)
    if args.plant:
        # Simulate duplicate quantizer work in the disposable harness. Same
        # production scoring algorithm and pixels, not a fabricated time delta.
        thumb = helper._thumbnail(wallpaper)
        extra_start = time.perf_counter_ns()
        for _ in range(8):
            scored = helper._score(str(thumb))
            extra_checksums.append(hashlib.sha256(repr(scored).encode()).hexdigest())
            extra_count += 1
        extra_ns = time.perf_counter_ns() - extra_start
    elapsed = time.perf_counter_ns() - start
    if not result.colours.get("primary"):
        raise RuntimeError("Scheme work produced no palette.")
    values[name] = elapsed / 1e6
    work.append({"metric": name, "elapsedNs": elapsed, "extraQuantizations": extra_count,
                 "extraQuantizationNs": extra_ns, "extraQuantizationChecksums": extra_checksums,
                 "paletteSha256": hashlib.sha256(str(result.colours).encode()).hexdigest()})
record = {"values": values, "work": work, "privacy": "PRIVATE-local-evidence; never upload raw receipts automatically",
          "helperSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
          "imageSha256": hashlib.sha256(wallpaper.read_bytes()).hexdigest(),
          "python": sys.version, "packages": {
              n: importlib.metadata.version(n) for n in ("caelestia", "pillow", "materialyoucolor")}}
(root / "trial.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
