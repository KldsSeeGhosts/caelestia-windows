#!/usr/bin/env python3
"""Windows scheme bridge for the isolated Caelestia prototype profile.

This runs the upstream caelestia CLI's own scheme generation code (the
``caelestia.utils.scheme`` / ``caelestia.utils.material`` / ``Pillow`` modules
that ``caelestia scheme set`` and ``caelestia wallpaper -p`` use) and writes
``<profile>/state/caelestia/scheme.json``, the file ``services/Colours.qml``
watches.

It deliberately does not import or run the upstream theme writer: that module is
Linux-only (fcntl locks, Hyprland sockets, dconf, /dev/pts and ``killall``), and
on Windows the QML shell itself is the only theme consumer. The CLI package is
installed unchanged into a profile-local virtual environment; only the scheme
data and colour algorithms are used here.

All output is a single JSON object on stdout. Library chatter is redirected to
stderr so the QML caller can parse stdout unconditionally.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import sys
import traceback
import types
from pathlib import Path

# The installed generation is immutable while a shell is using it. Do not let
# Python add __pycache__ files to the published runtime.
sys.dont_write_bytecode = True

# The package __init__ imports the Linux-only theme writer, which imports fcntl.
# Register a tiny in-process stand-in before any caelestia import so this bridge
# works even when the venv shim has not been installed yet.
if sys.platform == "win32" and "fcntl" not in sys.modules:
    try:
        import fcntl  # noqa: F401
    except ImportError:
        _fcntl = types.ModuleType("fcntl")
        _fcntl.LOCK_SH = 1
        _fcntl.LOCK_EX = 2
        _fcntl.LOCK_NB = 4
        _fcntl.LOCK_UN = 8

        def _flock(fd: int, operation: int) -> None:  # noqa: ARG001
            # Advisory-only: the bridge never runs two scheme writers at once.
            return None

        _fcntl.flock = _flock
        sys.modules["fcntl"] = _fcntl

# Refuse to fall back to the user's real Linux-style paths. The launcher sets
# CAELESTIA_PROFILE_ROOT for the whole shell process.
_profile = os.environ.get("CAELESTIA_PROFILE_ROOT")
if not _profile:
    print(json.dumps({"ok": False, "error": "CAELESTIA_PROFILE_ROOT is not set; refusing to write outside the prototype profile"}))
    raise SystemExit(2)
_profile_root = Path(_profile).resolve()
os.environ["XDG_STATE_HOME"] = str(_profile_root / "state")
os.environ["XDG_CACHE_HOME"] = str(_profile_root / "cache")
os.environ["XDG_CONFIG_HOME"] = str(_profile_root / "config")
os.environ["XDG_DATA_HOME"] = str(_profile_root / "data")

# A warm worker's stdout is a request/response channel. Anything the libraries
# print while importing must not be mistaken for a response line.
with contextlib.redirect_stdout(sys.stderr):
    from PIL import Image  # noqa: E402

    from caelestia.utils.paths import (  # noqa: E402
        scheme_path,
        wallpaper_path_path,
        wallpaper_thumbnail_path,
        wallpapers_cache_dir,
    )
    from caelestia.utils.scheme import (  # noqa: E402
        Scheme,
        get_scheme,
        get_scheme_flavours,
        get_scheme_modes,
        get_scheme_names,
        scheme_variants,
    )


def _hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(8192):
            digest.update(chunk)
    return digest.hexdigest()


def _thumbnail(image: Path) -> Path:
    """Match the upstream thumbnail: 128x128 fit, nearest resample, JPEG."""
    cache = wallpapers_cache_dir / _hash(image)
    thumb = cache / "thumbnail.jpg"
    if not thumb.exists():
        with Image.open(image) as img:
            img.seek(0)  # WE previews can be animated GIF/WebP. Sample frame 0.
            img = img.convert("RGB")
            img.thumbnail((128, 128), Image.Resampling.NEAREST)
            thumb.parent.mkdir(parents=True, exist_ok=True)
            img.save(thumb, "JPEG")
    return thumb


def _seed_wallpaper(image: Path) -> None:
    """Write the regular-file state the dynamic scheme generator reads.

    Upstream uses symlinks for ``current`` and ``thumbnail.jpg``. Windows only
    allows symlinks with extra privileges, so the bridge writes ordinary files:
    the generator only reads ``thumbnail.jpg`` and ``path.txt``.
    """
    thumb = _thumbnail(image)
    wallpaper_thumbnail_path.parent.mkdir(parents=True, exist_ok=True)
    if wallpaper_thumbnail_path.is_symlink():
        wallpaper_thumbnail_path.unlink()
    shutil.copyfile(thumb, wallpaper_thumbnail_path)
    wallpaper_path_path.parent.mkdir(parents=True, exist_ok=True)
    wallpaper_path_path.write_text(str(image))


def _smart_options(image: Path) -> dict[str, str]:
    from caelestia.utils.wallpaper import get_smart_opts

    # Feed the same decoded still frame to smart luminance analysis as to the
    # quantizer. Some image-analysis libraries do not accept animated inputs.
    with Image.open(image) as img:
        animated = getattr(img, "is_animated", False)
    return get_smart_opts(_thumbnail(image) if animated else image, wallpapers_cache_dir / _hash(image))


def _validated(name: str, flavour: str | None, mode: str | None, variant: str | None, fallback_variant: str) -> tuple[str, str, str, str]:
    if name not in get_scheme_names():
        raise ValueError(f"unknown scheme: {name}")
    flavours = get_scheme_flavours(name)
    flavour = flavour if flavour in flavours else flavours[0]
    modes = get_scheme_modes(name, flavour)
    mode = mode if mode in modes else modes[0]
    variant = variant if variant in scheme_variants else fallback_variant
    if variant not in scheme_variants:
        variant = "tonalspot"
    return name, flavour, mode, variant


def _save_scheme(name: str, flavour: str | None, mode: str | None, variant: str | None) -> Scheme:
    # Mutate the process-global Scheme rather than constructing a second one:
    # upstream get_colours_for_image() resolves its scheme through get_scheme(),
    # so a throwaway object would generate colours for the stale global fields.
    scheme = get_scheme()
    name, flavour, mode, variant = _validated(name, flavour, mode, variant, scheme.variant)
    scheme._name = name
    scheme._flavour = flavour
    scheme._mode = mode
    scheme._variant = variant
    scheme._update_colours()
    scheme.save()
    return scheme


def _describe(scheme: Scheme) -> dict:
    return {
        "ok": True,
        "name": scheme.name,
        "flavour": scheme.flavour,
        "mode": scheme.mode,
        "variant": scheme.variant,
        "colours": scheme.colours,
        "path": str(scheme_path),
    }


def _current_wallpaper() -> Path | None:
    try:
        value = wallpaper_path_path.read_text().strip()
    except OSError:
        return None
    if not value:
        return None
    path = Path(value)
    return path if path.is_file() else None


def apply_wallpaper(image: Path, flavour: str | None, mode: str | None, variant: str | None, smart: bool) -> Scheme:
    image = image.resolve()
    if not image.is_file():
        raise ValueError(f"wallpaper not found: {image}")
    _seed_wallpaper(image)

    current = get_scheme()
    target_mode = mode
    target_variant = variant
    if smart and not mode and not variant:
        options = _smart_options(image)
        target_mode = options.get("mode", current.mode)
        target_variant = options.get("variant", current.variant)
    target_mode = target_mode or current.mode
    target_variant = target_variant or current.variant
    return _save_scheme("dynamic", flavour or current.flavour, target_mode, target_variant)


def set_properties(
    name: str | None,
    flavour: str | None,
    mode: str | None,
    variant: str | None,
    image: Path | None = None,
) -> Scheme:
    current = get_scheme()
    target = name or current.name
    # The QML caller passes the current Windows wallpaper so light/dark and
    # variant changes work before the picker has ever run.
    if image is None or not image.is_file():
        image = _current_wallpaper()

    if target == "dynamic":
        if image is None:
            raise ValueError("no wallpaper is set; choose a wallpaper before the dynamic scheme")
        return apply_wallpaper(image, flavour, mode, variant, smart=False)

    if mode is not None and mode not in get_scheme_modes(target, flavour or current.flavour):
        # A light/dark switch of a static scheme without that mode is best
        # served by the wallpaper palette the prototype uses.
        if image is not None:
            return apply_wallpaper(image, flavour, mode, variant, smart=False)
        raise ValueError(f'scheme "{target}" has no {mode} mode')

    if variant is not None and name is None:
        # A variant only changes generated colours. Keep the chosen scheme name
        # when possible by switching to the wallpaper-derived dynamic palette.
        if image is not None:
            return apply_wallpaper(image, flavour, None, variant, smart=False)
        raise ValueError("a scheme variant needs a wallpaper palette; choose a wallpaper first")

    return _save_scheme(target, flavour, mode, variant)


def list_schemes() -> dict:
    current = get_scheme()
    schemes: dict[str, dict[str, dict[str, str]]] = {}
    for name in get_scheme_names():
        schemes[name] = {}
        for flavour in get_scheme_flavours(name):
            modes = get_scheme_modes(name, flavour)
            mode = current.mode if current.mode in modes else modes[0]
            try:
                scheme = Scheme({
                    "name": name,
                    "flavour": flavour,
                    "mode": mode,
                    "variant": current.variant,
                    "colours": current.colours,
                })
                scheme._update_colours()
            except (OSError, ValueError):
                continue
            schemes[name][flavour] = scheme.colours
    return {
        "ok": True,
        "schemes": schemes,
        "current": {
            "name": current.name,
            "flavour": current.flavour,
            "mode": current.mode,
            "variant": current.variant,
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="win_scheme")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("list")

    apply_parser = commands.add_parser("apply-wallpaper")
    apply_parser.add_argument("--image", required=True)
    apply_parser.add_argument("--flavour")
    apply_parser.add_argument("--mode", choices=["light", "dark"])
    apply_parser.add_argument("--variant", choices=scheme_variants)
    apply_parser.add_argument("--smart", choices=["0", "1"], default="1")

    set_parser = commands.add_parser("set")
    set_parser.add_argument("--name")
    set_parser.add_argument("--flavour")
    set_parser.add_argument("--mode", choices=["light", "dark"])
    set_parser.add_argument("--variant", choices=scheme_variants)
    set_parser.add_argument("--image")

    mode_parser = commands.add_parser("set-mode")
    mode_parser.add_argument("--mode", required=True, choices=["light", "dark"])
    mode_parser.add_argument("--image")

    variant_parser = commands.add_parser("set-variant")
    variant_parser.add_argument("--variant", required=True, choices=scheme_variants)
    variant_parser.add_argument("--image")

    commands.add_parser("current")

    return parser


def _dispatch(args: argparse.Namespace) -> dict:
    if args.command == "list":
        return list_schemes()
    if args.command == "apply-wallpaper":
        return _describe(apply_wallpaper(
            Path(args.image), args.flavour, args.mode, args.variant, args.smart == "1",
        ))
    if args.command == "set":
        return _describe(set_properties(
            args.name, args.flavour, args.mode, args.variant,
            Path(args.image) if args.image else None,
        ))
    if args.command == "set-mode":
        return _describe(set_properties(
            None, None, args.mode, None, Path(args.image) if args.image else None,
        ))
    if args.command == "set-variant":
        return _describe(set_properties(
            None, None, None, args.variant, Path(args.image) if args.image else None,
        ))
    current = get_scheme()
    return {
        "ok": True,
        "name": current.name,
        "flavour": current.flavour,
        "mode": current.mode,
        "variant": current.variant,
        "path": str(scheme_path),
    }


def _emit(result: dict) -> None:
    """Write exactly one response line. Library chatter goes to stderr."""
    sys.stdout.write(json.dumps(result, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def _run(argv: list[str]) -> dict:
    args = _parser().parse_args(argv)
    with contextlib.redirect_stdout(sys.stderr):
        return _dispatch(args)


def serve() -> int:
    """Keep the imports and the upstream per-image cache warm between changes.

    The shell starts this once and writes one JSON request per line. Spawning
    an interpreter and importing Pillow/caelestia for every wallpaper switch is
    the dominant generation cost on Windows; the command implementations are
    the same as the one-shot CLI, so colours are unchanged.
    """
    for raw in sys.stdin.buffer:
        line = raw.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            argv = request.get("args") if isinstance(request, dict) else None
            if (not isinstance(argv, list) or not argv
                    or not all(isinstance(arg, str) for arg in argv)
                    or argv[0] == "serve"):
                raise ValueError("invalid scheme request")
            result = _run(argv)
        except SystemExit:
            # argparse reports usage on stderr and exits; keep serving.
            result = {"ok": False, "error": "invalid scheme request"}
        except Exception as exc:  # a failed request must not stop the worker
            traceback.print_exc(file=sys.stderr)
            result = {"ok": False, "error": str(exc)}
        _emit(result)
    return 0


def main(argv: list[str]) -> int:
    if argv == ["serve"]:
        return serve()
    try:
        result = _run(argv)
        code = 0
    except Exception as exc:  # report a parseable failure, never a bare traceback on stdout
        traceback.print_exc(file=sys.stderr)
        result = {"ok": False, "error": str(exc)}
        code = 1
    _emit(result)
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
