"""Wallpaper Engine discovery and official CLI dispatch. No config writes."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import getpass
import json
import os
from pathlib import Path
import re
import subprocess
import winreg


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def libraries() -> list[Path]:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
        steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
    # VDF quoted path values, including Steam's escaped Windows separators.
    text = (steam / "steamapps/libraryfolders.vdf").read_text(encoding="utf-8")
    paths = [steam]
    for value in re.findall(r'"path"\s*"((?:\\.|[^"\\])*)"', text):
        path = Path(value.replace("\\\\", "\\").replace('\\"', '"'))
        if path not in paths:
            paths.append(path)
    return paths


def install(libs: list[Path]) -> Path | None:
    for library in libs:
        manifest = library / "steamapps/appmanifest_431960.acf"
        if not manifest.is_file():
            continue
        match = re.search(r'"installdir"\s*"([^"]+)"', manifest.read_text(encoding="utf-8"))
        if match:
            directory = library / "steamapps/common" / match[1]
            if (directory / "wallpaper64.exe").is_file():
                return directory
    return None


def running() -> bool:
    class Entry(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
            ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260),
        ]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateToolhelp32Snapshot(2, 0)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(entry)
        found = kernel.Process32FirstW(handle, ctypes.byref(entry))
        while found:
            if entry.szExeFile.lower() in ("wallpaper64.exe", "wallpaper32.exe"):
                return True
            found = kernel.Process32NextW(handle, ctypes.byref(entry))
        return False
    finally:
        kernel.CloseHandle(handle)


def project(path: Path) -> dict:
    path = path if path.name.lower() == "project.json" else path.parent / "project.json"
    data = read_json(path)
    preview = (path.parent / data.get("preview", "")).resolve()
    # A project preview must stay inside its workshop/project directory.
    if not preview.is_relative_to(path.parent.resolve()) or not preview.is_file():
        preview_value = ""
    else:
        preview_value = preview.as_posix()
    return {
        "path": path.resolve().as_posix(), "preview": preview_value,
        "title": str(data.get("title") or path.parent.name),
        "relativePath": str(data.get("title") or path.parent.name),
        "type": str(data.get("type", "")), "engine": True,
    }


def snapshot(status_only: bool = False) -> dict:
    active = running()
    try:
        return catalog_snapshot(active, status_only)
    except (OSError, ValueError, KeyError) as error:
        # Process liveness is independent of config/catalogue readability.
        # In particular, a stopped engine plus a partial config write must
        # release the shell's external-owner guard, not retain stale "running".
        return {"ok": True, "running": active, "discoveryError": str(error)}


def catalog_snapshot(active: bool, status_only: bool) -> dict:
    try:
        libs = libraries()
    except FileNotFoundError:
        return {"ok": True, "detected": False, "running": active, "active": {}, "items": [], "monitors": {}}
    directory = install(libs)
    if directory is None:
        return {"ok": True, "detected": False, "running": active, "active": {}, "items": [], "monitors": {}}
    config_path = directory / "config.json"
    config = read_json(config_path)
    # Only the active user's wallpaperconfig. Do not recurse through recent
    # layouts, which contain stale selectedwallpapers with the same keys.
    try:
        login = os.getlogin()
    except OSError:
        # Service-spawned helpers have no console to resolve the login name.
        login = os.environ.get("USERNAME") or getpass.getuser()
    user = next((key for key in config if key.casefold() == login.casefold()), None)
    if user is None:
        candidates = [key for key, value in config.items()
                      if isinstance(value, dict) and "wallpaperconfig" in value.get("general", {})]
        if len(candidates) != 1:
            raise ValueError("cannot identify the active Wallpaper Engine config user")
        user = candidates[0]
    selected = config[user].get("general", {}).get("wallpaperconfig", {}).get("selectedwallpapers", {})
    active_files = {
        str(monitor): str(value.get("file", ""))
        for monitor, value in sorted(selected.items())
        if isinstance(value, dict)
    }
    executable = (directory / "wallpaper64.exe").as_posix()
    if status_only:
        return {
            "ok": True, "detected": True, "running": active,
            "configPath": config_path.as_posix(), "executable": executable,
            "active": active_files,
        }
    monitors = {}
    for monitor, value in selected.items():
        try:
            monitors[monitor] = project(Path(value["file"]))
        except (OSError, ValueError, KeyError):
            monitors[monitor] = {"path": "", "preview": "", "title": "", "engine": True}
    items = []
    for library in libs:
        workshop = library / "steamapps/workshop/content/431960"
        if workshop.is_dir():
            for entry in workshop.iterdir():
                try:
                    items.append(project(entry / "project.json"))
                except (OSError, ValueError):
                    continue
    items.sort(key=lambda item: item["title"].casefold())
    return {
        "ok": True, "detected": True, "running": active,
        "configPath": config_path.as_posix(), "executable": executable,
        "active": active_files, "monitors": monitors, "items": items,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["snapshot", "open"])
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--project")
    parser.add_argument("--monitor", type=int)
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            result = snapshot(status_only=args.status_only)
        else:
            if os.environ.get("CAELESTIA_COMBINED_LIVE") != "1" or os.environ.get("CAELESTIA_SHELL_SMOKE") == "1":
                raise ValueError("Wallpaper Engine controls are disabled")
            state = snapshot()
            if state.get("discoveryError"):
                raise ValueError(state["discoveryError"])
            target = Path(args.project or "").resolve()
            if not state["detected"] or not state["running"]:
                raise ValueError("Wallpaper Engine is not running")
            if str(target).casefold() not in {str(Path(item["path"])).casefold() for item in state["items"]}:
                raise ValueError("project is not in the discovered workshop catalog")
            command = [state["executable"], "-control", "openWallpaper", "-file", str(target)]
            if args.monitor is not None:
                command += ["-monitor", str(args.monitor)]
            subprocess.run(command, check=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
            result = {"ok": True, "requested": target.as_posix()}
        print(json.dumps(result, ensure_ascii=True))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
