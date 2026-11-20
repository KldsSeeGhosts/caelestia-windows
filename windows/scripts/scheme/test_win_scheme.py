"""Regressions for the warm scheme worker and its downscaled inputs.

The provisioned scheme runtime is the only interpreter that can import the
caelestia CLI, Pillow and materialyoucolor, so Test-SchemeRuntime.ps1 runs this
file with it. Everything runs in a temporary profile: the live profile is never
read or written.
"""

from __future__ import annotations

import atexit
import sys

# The provisioned runtime is immutable and the tests import the helper from
# the repository; never add __pycache__ next to either.
sys.dont_write_bytecode = True

import importlib
import importlib.util
import io
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).with_name("win_scheme.py")

# win_scheme derives every state/cache path from the profile root at import.
_PROFILE = tempfile.TemporaryDirectory(prefix="caelestia-scheme-test-")
atexit.register(_PROFILE.cleanup)
os.environ["CAELESTIA_PROFILE_ROOT"] = _PROFILE.name

_spec = importlib.util.spec_from_file_location("win_scheme", HELPER)
ws = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ws)

from PIL import Image, ImageDraw  # noqa: E402

score_module = importlib.import_module("caelestia.utils.material.score")


def _image(directory: Path, name: str, size: tuple[int, int] = (2400, 1600)) -> Path:
    """A deterministic, colourful image big enough to make the downscale matter."""
    path = directory / name
    random.seed(7)
    img = Image.new("RGB", size, (24, 32, 48))
    draw = ImageDraw.Draw(img)
    for _ in range(24):
        x = random.randrange(0, size[0])
        y = random.randrange(0, size[1])
        radius = random.randrange(size[0] // 20, size[0] // 5)
        colour = (random.randrange(256), random.randrange(256), random.randrange(256))
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=colour)
    img.save(path, "JPEG", quality=90)
    return path


def _decode(line: str) -> dict:
    return json.loads(line)


class ThumbnailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-image-")).resolve()
        self.addCleanup(shutil.rmtree, self.directory, True)

    def _legacy_jpeg(self, path: Path) -> bytes:
        """The pre-optimisation pipeline: full-size RGB convert, then resize."""
        buffer = io.BytesIO()
        with Image.open(path) as img:
            img.seek(0)
            rgb = img.convert("RGB")
            rgb.thumbnail((128, 128), Image.Resampling.NEAREST)
            rgb.save(buffer, "JPEG")
        return buffer.getvalue()

    def test_thumbnail_matches_upstream_size_and_is_cached(self):
        image = _image(self.directory, "large-2400.jpg")
        thumb = ws._thumbnail(image)
        self.assertTrue(thumb.is_file())
        with Image.open(thumb) as decoded:
            self.assertLessEqual(max(decoded.size), 128)
        # Cached upstream shape: hash-named directory with thumbnail.jpg.
        self.assertEqual(thumb, ws.wallpapers_cache_dir / ws._hash(image) / "thumbnail.jpg")
        before = thumb.stat().st_mtime_ns
        self.assertEqual(ws._thumbnail(image), thumb)
        self.assertEqual(thumb.stat().st_mtime_ns, before)

    def test_thumbnail_jpeg_bytes_match_legacy_for_common_formats(self):
        random.seed(11)
        base = Image.new("RGB", (900, 640), (200, 60, 40))
        draw = ImageDraw.Draw(base)
        for _ in range(40):
            x = random.randrange(0, 900)
            y = random.randrange(0, 640)
            colour = (random.randrange(256), random.randrange(256), random.randrange(256))
            draw.rectangle((x, y, x + random.randrange(30, 180), y + random.randrange(30, 120)), fill=colour)

        cases: dict[str, Path] = {}
        rgb_jpeg = self.directory / "rgb.jpg"
        base.save(rgb_jpeg, "JPEG", quality=95)
        cases["rgb.jpg"] = rgb_jpeg

        cmyk_jpeg = self.directory / "cmyk.jpg"
        base.convert("CMYK").save(cmyk_jpeg, "JPEG", quality=95)
        cases["cmyk.jpg"] = cmyk_jpeg

        rgb_png = self.directory / "rgb.png"
        base.save(rgb_png, "PNG")
        cases["rgb.png"] = rgb_png

        palette_png = self.directory / "palette.png"
        base.convert("P", palette=Image.Palette.ADAPTIVE).save(palette_png, "PNG")
        cases["palette.png"] = palette_png

        alpha_png = self.directory / "alpha.png"
        rgba = base.convert("RGBA")
        alpha = rgba.getchannel("A").point(lambda _: 160)
        rgba.putalpha(alpha)
        rgba.save(alpha_png, "PNG")
        cases["alpha.png"] = alpha_png

        bmp = self.directory / "rgb.bmp"
        base.save(bmp, "BMP")
        cases["rgb.bmp"] = bmp

        grey = self.directory / "grey.tiff"
        base.convert("L").save(grey, "TIFF")
        cases["grey.tiff"] = grey

        animated = self.directory / "animated.gif"
        frame_two = base.point(lambda p: 255 - p)
        base.convert("P", palette=Image.Palette.ADAPTIVE).save(
            animated, "GIF", save_all=True,
            append_images=[frame_two.convert("P", palette=Image.Palette.ADAPTIVE)],
            duration=80, loop=0,
        )
        cases["animated.gif"] = animated

        small = self.directory / "small.png"
        base.crop((0, 0, 96, 64)).save(small, "PNG")
        cases["small.png"] = small

        webp = self.directory / "rgb.webp"
        try:
            base.save(webp, "WEBP", quality=92)
        except OSError:
            pass
        else:
            cases["rgb.webp"] = webp

        for name, path in cases.items():
            with self.subTest(name=name):
                thumb = ws._thumbnail(path)
                self.assertEqual(
                    thumb.read_bytes(), self._legacy_jpeg(path),
                    f"{name}: thumbnail bytes differ from the convert-first pipeline",
                )

    def test_thumbnail_never_converts_a_full_size_copy(self):
        palette_png = self.directory / "palette-large.png"
        _img = Image.new("RGB", (1600, 1200), (10, 90, 30))
        _img.convert("P", palette=Image.Palette.ADAPTIVE).save(palette_png, "PNG")

        converted_sizes: list[tuple[int, int]] = []
        real_convert = Image.Image.convert

        def spy(self: Image.Image, *args, **kwargs):
            converted_sizes.append(self.size)
            return real_convert(self, *args, **kwargs)

        with patch.object(Image.Image, "convert", spy):
            ws._thumbnail(palette_png)

        self.assertTrue(converted_sizes, "a palette image should still be converted to RGB")
        for size in converted_sizes:
            self.assertLessEqual(max(size), 128, "convert ran on a full-size copy")

    def test_thumbnail_falls_back_to_convert_first_when_resize_rejects_a_mode(self):
        palette_png = self.directory / "palette-fallback.png"
        Image.new("RGB", (1400, 900), (70, 20, 110)).convert(
            "P", palette=Image.Palette.ADAPTIVE,
        ).save(palette_png, "PNG")

        real_thumbnail = Image.Image.thumbnail

        def reject_palette(self: Image.Image, *args, **kwargs):
            if self.mode == "P" and max(self.size) > 128:
                raise NotImplementedError("in-place resize refused for this mode")
            return real_thumbnail(self, *args, **kwargs)

        with patch.object(Image.Image, "thumbnail", reject_palette):
            thumb = ws._thumbnail(palette_png)
        self.assertEqual(thumb.read_bytes(), self._legacy_jpeg(palette_png))

    def test_apply_wallpaper_hashes_the_source_once_per_request(self):
        image = _image(self.directory, "hashed-once.jpg", (1200, 900))
        calls = 0
        real_hash = ws._hash

        def count(path: Path) -> str:
            nonlocal calls
            calls += 1
            return real_hash(path)

        with patch.object(ws, "_hash", count):
            result = ws.apply_wallpaper(image, None, None, None, True)

        self.assertTrue(result.colours["primary"])
        self.assertEqual(calls, 1, "the source file should be hashed once per request")

    def test_quantisation_reads_the_downscaled_thumbnail(self):
        image = _image(self.directory, "large-2000.jpg", (2000, 1400))
        seen: list[Path] = []
        real_score = score_module.score

        def record(path: str):
            seen.append(Path(path))
            return real_score(path)

        with patch.object(score_module, "score", record):
            result = ws.apply_wallpaper(image, None, None, None, True)

        self.assertTrue(result.colours["primary"])
        self.assertEqual(len(seen), 1)
        # The quantizer must never see the source image: the wallpaper
        # thumbnail is the seeded 128px JPEG that upstream caelestia scores.
        self.assertEqual(seen[0], ws.wallpaper_thumbnail_path)
        self.assertNotEqual(seen[0], image)
        with Image.open(seen[0]) as decoded:
            self.assertLessEqual(max(decoded.size), 128)

    def test_per_image_cache_skips_quantisation_on_revisit(self):
        image = _image(self.directory, "revisit.jpg", (1600, 1200))
        calls = 0
        real_score = score_module.score

        def count(path: str):
            nonlocal calls
            calls += 1
            return real_score(path)

        with patch.object(score_module, "score", count):
            first = dict(ws.apply_wallpaper(image, None, None, None, True).colours)
            second = dict(ws.apply_wallpaper(image, None, None, None, True).colours)

        self.assertEqual(calls, 1)
        self.assertEqual(first, second)

    def test_dynamic_palette_keeps_upstream_colours_and_separate_tint(self):
        from caelestia.utils.material import get_colours_for_image

        image = _image(self.directory, "surface-tint.jpg")
        for mode in ("dark", "light"):
            with self.subTest(mode=mode):
                scheme = ws.apply_wallpaper(image, None, mode, "tonalspot", False)
                upstream = get_colours_for_image(scheme=scheme)
                saved = json.loads(ws.scheme_path.read_bytes())
                self.assertEqual(saved["colours"], upstream)
                self.assertEqual(scheme.colours, upstream)
                overrides = saved["windowsSurfaceTint"]
                self.assertNotIn("primary", overrides)
                self.assertNotIn("onSurface", overrides)
                for role in ("surface", "surfaceContainer"):
                    before = ws.Hct.from_int(int(upstream[role], 16))
                    after = ws.Hct.from_int(int(overrides[role], 16))
                    self.assertGreater(after.chroma, before.chroma + 3)
                    self.assertAlmostEqual(after.tone, before.tone, delta=0.5)

        for variant in ("monochrome", "neutral"):
            with self.subTest(variant=variant):
                scheme = ws.apply_wallpaper(image, None, "dark", variant, False)
                self.assertEqual(scheme.colours, get_colours_for_image(scheme=scheme))
                self.assertEqual(json.loads(ws.scheme_path.read_bytes())["windowsSurfaceTint"], {})


class UnicodePathTests(unittest.TestCase):
    """Non-ASCII paths must survive argv, the persisted path file and output."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-unicode-")).resolve()
        self.addCleanup(shutil.rmtree, self.directory, True)

    def _round_trip(self, profile_name: str, folder_name: str, image_name: str) -> None:
        folder = self.directory / folder_name
        folder.mkdir()
        image = _image(folder, image_name, (1440, 1000))
        profile = self.directory / profile_name
        env = {
            **os.environ,
            "CAELESTIA_PROFILE_ROOT": str(profile),
            # Reproduce the Windows cp1252 default this fix is for, even when
            # the test runner itself inherited UTF-8 mode.
            "PYTHONUTF8": "0",
            "PYTHONIOENCODING": "cp1252",
        }

        first = subprocess.run(
            [sys.executable, str(HELPER), "apply-wallpaper", "--image", str(image), "--smart", "0"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            cwd=self.directory,
            check=False,
        )
        self.assertEqual(first.returncode, 0, first.stderr[-4000:])
        applied = json.loads(first.stdout)
        self.assertTrue(applied["ok"], first.stdout)
        self.assertTrue(applied["colours"]["primary"])
        source = profile / "state" / "caelestia" / "wallpaper" / "path.txt"
        self.assertEqual(source.read_text(encoding="utf-8"), str(image.resolve()))

        # A mode change need not pass the image again: the persisted path must
        # read back to the same file, not fall back to "no wallpaper is set".
        second = subprocess.run(
            [sys.executable, str(HELPER), "set-mode", "--mode", "dark"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            cwd=self.directory,
            check=False,
        )
        self.assertEqual(second.returncode, 0, second.stderr[-4000:])
        result = json.loads(second.stdout)
        self.assertTrue(result["ok"], second.stdout)
        self.assertEqual(result["path"], str(profile / "state" / "caelestia" / "scheme.json"))

    def test_cjk_wallpaper_path(self) -> None:
        self._round_trip("プロファイル", "壁紙テスト", "背景画像.jpg")

    def test_accented_latin_wallpaper_path(self) -> None:
        self._round_trip("Profil café", "Café façade", "Crème brûlée.jpg")

    def test_legacy_cp1252_path_file_survives_mode_change(self) -> None:
        # An older helper applied this wallpaper under cp1252, so path.txt holds
        # the accented source path in that code page. The thumbnail and scheme
        # from a current apply stand in for that parent run; only the path file
        # is rewound to the bytes the old writer produced.
        folder = self.directory / "wallpapers"
        folder.mkdir()
        image = _image(folder, "Café.jpg", (1440, 1000))
        profile = self.directory / "profile"
        env = {
            **os.environ,
            "CAELESTIA_PROFILE_ROOT": str(profile),
            "PYTHONUTF8": "0",
            "PYTHONIOENCODING": "cp1252",
        }
        applied = subprocess.run(
            [sys.executable, str(HELPER), "apply-wallpaper", "--image", str(image), "--smart", "0"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            cwd=self.directory,
            check=False,
        )
        self.assertEqual(applied.returncode, 0, applied.stderr[-4000:])
        source = profile / "state" / "caelestia" / "wallpaper" / "path.txt"
        resolved = str(image.resolve())
        source.write_bytes(resolved.encode("cp1252"))
        changed = subprocess.run(
            [sys.executable, str(HELPER), "set-mode", "--mode", "light"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            cwd=self.directory,
            check=False,
        )
        self.assertEqual(changed.returncode, 0, changed.stderr[-4000:])
        result = json.loads(changed.stdout)
        self.assertTrue(result["ok"], changed.stdout)
        self.assertEqual(source.read_text(encoding="utf-8"), resolved)


def _stop(worker: subprocess.Popen) -> None:
    if worker.poll() is None:
        worker.kill()
    worker.wait(timeout=30)
    for stream in (worker.stdin, worker.stdout):
        if stream and not stream.closed:
            stream.close()


class WarmWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-worker-")).resolve()
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.profile = self.directory / "profile"

    def _start(self, **environment: str) -> subprocess.Popen:
        worker = subprocess.Popen(
            [sys.executable, str(HELPER), "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            env={**os.environ, "CAELESTIA_PROFILE_ROOT": str(self.profile), **environment},
        )
        self.addCleanup(_stop, worker)
        return worker

    def _request(self, worker: subprocess.Popen, args: list[str]) -> dict:
        worker.stdin.write(json.dumps({"args": args}) + "\n")
        worker.stdin.flush()
        line = worker.stdout.readline()
        self.assertTrue(line, "the warm worker stopped answering")
        return _decode(line)

    def _close(self, worker: subprocess.Popen) -> None:
        worker.stdin.close()
        self.assertEqual(worker.wait(timeout=30), 0)

    def test_preview_is_read_only_and_matches_the_committed_palette(self):
        first = _image(self.directory, "committed.jpg", (720, 480))
        second = _image(self.directory, "highlighted.jpg", (480, 720))
        worker = self._start()
        state = self.profile / "state" / "caelestia"
        cold = self._request(worker, ["preview-wallpaper", "--image", str(first)])
        self.assertTrue(cold["ok"], cold)
        self.assertFalse(state.exists(), "preview created state before the first commit")
        applied = self._request(worker, ["apply-wallpaper", "--image", str(first)])
        self.assertTrue(applied["ok"], applied)
        self.assertEqual(cold["colours"], applied["colours"])
        persisted = [
            state / "scheme.json",
            state / "wallpaper" / "path.txt",
            state / "wallpaper" / "thumbnail.jpg",
        ]
        before = [(file.stat().st_mtime_ns, file.read_bytes()) for file in persisted]
        preview = self._request(worker, ["preview-wallpaper", "--image", str(second), "--smart", "0"])
        self.assertTrue(preview["ok"], preview)
        self.assertEqual((preview["mode"], preview["variant"]), (applied["mode"], applied["variant"]))
        self.assertEqual([(file.stat().st_mtime_ns, file.read_bytes()) for file in persisted], before)
        chosen = self._request(worker, ["apply-wallpaper", "--image", str(second), "--smart", "0"])
        self.assertTrue(chosen["ok"], chosen)
        self.assertEqual(chosen["colours"], preview["colours"])
        self.assertEqual(chosen["windowsSurfaceTint"], preview["windowsSurfaceTint"])
        self._close(worker)

    def test_list_upgrades_a_legacy_tinted_palette_without_changing_its_variant(self):
        image = _image(self.directory, "legacy.jpg", (720, 480))
        worker = self._start()
        applied = self._request(worker, [
            "apply-wallpaper", "--image", str(image), "--mode", "light", "--variant", "expressive",
        ])
        self.assertTrue(applied["ok"], applied)
        self.assertTrue(applied["windowsSurfaceTint"])
        self._close(worker)
        path = self.profile / "state" / "caelestia" / "scheme.json"
        legacy = json.loads(path.read_bytes())
        legacy["colours"].update(legacy.pop("windowsSurfaceTint"))
        path.write_text(json.dumps(legacy), encoding="utf-8")

        worker = self._start()
        self.assertTrue(self._request(worker, ["list"])["ok"])
        migrated = json.loads(path.read_bytes())
        for key in ("mode", "variant", "flavour", "colours", "windowsSurfaceTint"):
            self.assertEqual(migrated[key], applied[key])
        self._close(worker)

    def test_worker_survives_a_failed_request(self):
        worker = self._start()
        self.assertTrue(self._request(worker, ["list"])["ok"])
        missing = self._request(worker, ["apply-wallpaper", "--image", str(self.directory / "missing.jpg")])
        self.assertFalse(missing["ok"])
        self.assertTrue(missing["error"])
        image = _image(self.directory, "after-error.jpg", (1440, 1000))
        recovered = self._request(worker, ["apply-wallpaper", "--image", str(image), "--smart", "1"])
        self.assertTrue(recovered["ok"])
        self._close(worker)

    def test_worker_accepts_non_ascii_paths(self):
        worker = self._start(PYTHONUTF8="0", PYTHONIOENCODING="cp1252")
        for folder_name, image_name in (
            ("壁紙テスト", "背景画像.jpg"),
            ("Café façade", "Crème brûlée.jpg"),
        ):
            folder = self.directory / folder_name
            folder.mkdir()
            image = _image(folder, image_name, (1440, 1000))
            result = self._request(worker, ["apply-wallpaper", "--image", str(image), "--smart", "0"])
            self.assertTrue(result["ok"], result)
            self.assertTrue(result["colours"]["primary"])
            source = self.profile / "state" / "caelestia" / "wallpaper" / "path.txt"
            self.assertEqual(source.read_text(encoding="utf-8"), str(image.resolve()))
        self._close(worker)

    def test_worker_matches_one_shot_colours_and_keeps_the_cache(self):
        image = _image(self.directory, "equivalent.jpg", (1440, 1000))
        one_shot = subprocess.run(
            [sys.executable, str(HELPER), "apply-wallpaper", "--image", str(image), "--smart", "1"],
            capture_output=True,
            text=True,
            env={**os.environ, "CAELESTIA_PROFILE_ROOT": str(self.directory / "one-shot")},
            check=False,
        )
        self.assertEqual(one_shot.returncode, 0, one_shot.stderr[-4000:])
        expected = json.loads(one_shot.stdout)

        worker = self._start()
        first = self._request(worker, ["apply-wallpaper", "--image", str(image), "--smart", "1"])
        self.assertTrue(first["ok"])
        self.assertEqual(first["colours"], expected["colours"])
        self.assertEqual(
            (first["name"], first["flavour"], first["mode"], first["variant"]),
            (expected["name"], expected["flavour"], expected["mode"], expected["variant"]),
        )

        # The upstream per-image cache lives under the worker's profile and is
        # reused by the next request, so no generation file is rewritten.
        thumbnail = self.profile / "state" / "caelestia" / "wallpaper" / "thumbnail.jpg"
        self.assertTrue(thumbnail.is_file())
        cached = (
            self.profile / "cache" / "caelestia" / "schemes" / ws._hash(thumbnail)
            / first["variant"] / first["flavour"] / first["mode"]
        ).with_suffix(".json")
        self.assertTrue(cached.is_file())
        before = cached.stat().st_mtime_ns
        second = self._request(worker, ["apply-wallpaper", "--image", str(image), "--smart", "1"])
        self.assertTrue(second["ok"])
        self.assertEqual(second["colours"], first["colours"])
        self.assertEqual(cached.stat().st_mtime_ns, before)
        self._close(worker)


if __name__ == "__main__":
    unittest.main()
