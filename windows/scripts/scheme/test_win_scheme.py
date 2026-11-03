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
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-image-"))
        self.addCleanup(shutil.rmtree, self.directory, True)

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


class UnicodePathTests(unittest.TestCase):
    """Non-ASCII paths must survive argv, the persisted path file and output."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-unicode-"))
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
        self.directory = Path(tempfile.mkdtemp(prefix="caelestia-scheme-worker-"))
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
