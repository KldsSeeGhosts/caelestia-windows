"""Wallpaper Engine discovery and official CLI dispatch. No config writes."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import getpass
import hashlib
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
            if any((directory / name).is_file() for name in ("wallpaper64.exe", "wallpaper32.exe")):
                return directory
    return None


def running_executable() -> str:
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
                return entry.szExeFile.lower()
            found = kernel.Process32NextW(handle, ctypes.byref(entry))
        return ""
    finally:
        kernel.CloseHandle(handle)


def running() -> bool:
    return bool(running_executable())


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


def selected_monitors(selected: dict) -> dict:
    """Resolve every selected project. A broken entry keeps its monitor key
    with empty fields, like a full catalogue scan, so the shell can fall back
    instead of silently keeping the previous wallpaper's palette."""
    monitors = {}
    for monitor, value in selected.items():
        try:
            monitors[str(monitor)] = project(Path(value["file"]))
        except (OSError, ValueError, KeyError, TypeError):
            monitors[str(monitor)] = {"path": "", "preview": "", "title": "", "engine": True}
    return monitors


def config_general(config: dict) -> dict:
    """Read only the active user's settings, never saved layouts."""
    try:
        login = os.getlogin()
    except OSError:
        login = os.environ.get("USERNAME") or getpass.getuser()
    user = next((key for key in config if key.casefold() == login.casefold()), None)
    if user is None:
        candidates = [key for key, value in config.items()
                      if isinstance(value, dict) and "wallpaperconfig" in value.get("general", {})]
        if len(candidates) != 1:
            raise ValueError("cannot identify the active Wallpaper Engine config user")
        user = candidates[0]
    return config[user].get("general", {})


def display_id(path: str) -> str:
    # Same normalization as Native.Wallpaper.screenTargetId. Device interfaces
    # stay inside their owning processes, not in QML, diagnostics or messages.
    return hashlib.sha256(path.replace("\\", "/").casefold().encode("utf-8")).hexdigest()


def active_display_ids() -> set[str]:
    """Revalidate an async request against the current Windows topology."""
    class Device(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("DeviceName", wintypes.WCHAR * 32),
                    ("DeviceString", wintypes.WCHAR * 128), ("StateFlags", wintypes.DWORD),
                    ("DeviceID", wintypes.WCHAR * 128), ("DeviceKey", wintypes.WCHAR * 128)]

    enum = ctypes.WinDLL("user32", use_last_error=True).EnumDisplayDevicesW
    enum.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(Device), wintypes.DWORD]
    enum.restype = wintypes.BOOL
    result = set()
    adapter_index = 0
    while True:
        adapter = Device()
        adapter.cb = ctypes.sizeof(adapter)
        if not enum(None, adapter_index, ctypes.byref(adapter), 0):
            break
        adapter_index += 1
        if not adapter.StateFlags & 1:  # DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
            continue
        monitor_index = 0
        while True:
            monitor = Device()
            monitor.cb = ctypes.sizeof(monitor)
            # EDD_GET_DEVICE_INTERFACE_NAME links GDI to the physical target.
            if not enum(adapter.DeviceName, monitor_index, ctypes.byref(monitor), 1):
                break
            monitor_index += 1
            if monitor.StateFlags & 1 and monitor.DeviceID:  # DISPLAY_DEVICE_ACTIVE
                result.add(display_id(monitor.DeviceID))
    return result


def screen_location(general: dict, target: str, active: set[str]) -> str:
    """Resolve an explicit screen to a selected-wallpaper internal ID.

    In managed mode the interface's saved location names MonitorN, not the
    Windows/Qt enumeration index. GDI aliases and timestamps are not routing
    authorities. Refuse missing/conflicting maps instead of changing Monitor0.
    """
    if not re.fullmatch(r"[0-9a-f]{64}", target) or target not in active:
        raise ValueError("The wallpaper display is no longer available")
    selected = general.get("wallpaperconfig", {}).get("selectedwallpapers", {})
    direct = [key for key in selected if display_id(key) == target]
    if len(direct) == 1:
        return direct[0]
    if direct:
        raise ValueError("Wallpaper Engine has an ambiguous display mapping")
    user = general.get("user", {})
    if user.get("monitordetection") != "managed":
        raise ValueError("Wallpaper Engine has no unambiguous mapping for this display")
    mapped = {}
    for key, value in user.get("monitormap", {}).items():
        # Only native interface keys can match a target digest. Ignore stale
        # GDI aliases, including aliases with conflicting location values.
        identity = display_id(key)
        if identity not in active or not isinstance(value, dict):
            continue
        location = value.get("location")
        if type(location) is not int or location < 0:
            raise ValueError("Wallpaper Engine has an invalid display mapping")
        if identity in mapped:
            raise ValueError("Wallpaper Engine has an ambiguous display mapping")
        mapped[identity] = f"Monitor{location}"
    location = mapped.get(target)
    if not location or location not in selected or list(mapped.values()).count(location) != 1:
        raise ValueError("Wallpaper Engine has no unambiguous mapping for this display")
    return location


def _is_direct_workshop_project(candidate: Path, location: Path) -> bool:
    """True for <workshop location>/<project>/project.json and nothing else."""
    candidate_parts = [part.casefold() for part in candidate.parts]
    location_parts = [part.casefold() for part in location.parts]
    return (len(candidate_parts) == len(location_parts) + 2
            and candidate_parts[:len(location_parts)] == location_parts
            and candidate_parts[-1] == "project.json")


def workshop_project(path: Path, libs: list[Path]) -> dict:
    """Validate one selected workshop project without scanning the catalogue.

    The full snapshot reads every project's project.json. A wallpaper selection
    only needs the project it names, but it still has to be a direct child of a
    Steam workshop location for Wallpaper Engine. resolve() follows junctions
    and symlinks, so a reparse point that leaves the location fails the check
    instead of being accepted by its displayed path.
    """
    candidate = Path(path)
    if candidate.name.casefold() != "project.json":
        candidate = candidate / "project.json"
    try:
        candidate = candidate.resolve()
    except OSError:
        raise ValueError("project is not in the discovered workshop catalog") from None
    for library in libs:
        try:
            location = (library / "steamapps/workshop/content/431960").resolve()
        except OSError:
            continue
        if not _is_direct_workshop_project(candidate, location):
            continue
        try:
            return project(candidate)
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            break
    raise ValueError("project is not in the discovered workshop catalog")


def open_wallpaper(project_path: str, monitor: int | None, screen_target: str | None) -> None:
    """Validate and dispatch one selection without rebuilding the catalogue."""
    if os.environ.get("CAELESTIA_COMBINED_LIVE") != "1" or os.environ.get("CAELESTIA_SHELL_SMOKE") == "1":
        raise ValueError("Wallpaper Engine controls are disabled")
    try:
        libs = libraries()
    except OSError:
        libs = []
    try:
        directory = install(libs) if libs else None
    except OSError:
        raise ValueError("Wallpaper Engine configuration is unavailable") from None
    if directory is None or not running():
        raise ValueError("Wallpaper Engine is not running")
    target = Path(workshop_project(Path(project_path), libs)["path"])
    executable = (directory / ("wallpaper64.exe" if (directory / "wallpaper64.exe").is_file()
                               else "wallpaper32.exe")).as_posix()
    command = [executable, "-control", "openWallpaper", "-file", str(target)]
    if screen_target is not None:
        try:
            general = config_general(read_json(directory / "config.json"))
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            raise ValueError("Wallpaper Engine configuration is unavailable") from None
        location = screen_location(general, screen_target, active_display_ids())
        command += ["-location", location]
    elif monitor is not None:
        command += ["-monitor", str(monitor)]
    else:
        raise ValueError("A wallpaper display is required")
    try:
        subprocess.run(command, check=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.SubprocessError, OSError):
        # subprocess exceptions contain the full command, including private
        # project paths and sometimes native monitor IDs.
        raise ValueError("Wallpaper Engine could not apply the wallpaper") from None


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
    selected = config_general(config).get("wallpaperconfig", {}).get("selectedwallpapers", {})
    active_files = {
        str(monitor): str(value.get("file", ""))
        for monitor, value in sorted(selected.items())
        if isinstance(value, dict)
    }
    executable = (directory / ("wallpaper64.exe" if (directory / "wallpaper64.exe").is_file()
                               else "wallpaper32.exe")).as_posix()
    # The selection watcher only needs the active projects. Resolving them in
    # status mode keeps a wallpaper change off the full-workshop-scan path;
    # the catalogue still refreshes on its own schedule.
    if status_only:
        return {
            "ok": True, "detected": True, "running": active,
            "configPath": config_path.as_posix(), "executable": executable,
            "active": active_files, "monitors": selected_monitors(selected),
        }
    monitors = selected_monitors(selected)
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


def control_desktop(action: str) -> None:
    """Stop/resume all displays without closing WE or rewriting its selection.

    https://help.wallpaperengine.io/en/functionality/cli.html documents stop
    and play as a reversible pair. closeWallpaper instead removes wallpapers.
    """
    if os.environ.get("CAELESTIA_COMBINED_LIVE") != "1" or os.environ.get("CAELESTIA_SHELL_SMOKE") == "1":
        raise ValueError("Wallpaper Engine controls are disabled")
    if action not in ("stop", "play"):
        raise ValueError("Unsupported Wallpaper Engine desktop control")
    # Revalidate liveness so an absent engine is never launched. This does
    # not depend on readable project/config files or a workshop catalogue.
    directory = install(libraries())
    executable = running_executable()
    if directory is None or not executable or not (directory / executable).is_file():
        raise ValueError("Wallpaper Engine is not running")
    try:
        subprocess.run([(directory / executable).as_posix(), "-control", action],
                       check=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.SubprocessError, OSError):
        raise ValueError("Wallpaper Engine could not change desktop playback") from None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["snapshot", "open", "stop", "play"])
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--project")
    parser.add_argument("--monitor", type=int)
    parser.add_argument("--screen-target")
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            result = snapshot(status_only=args.status_only)
        elif args.command in ("stop", "play"):
            control_desktop(args.command)
            result = {"ok": True}
        else:
            open_wallpaper(args.project or "", args.monitor, args.screen_target)
            result = {"ok": True}
        print(json.dumps(result, ensure_ascii=True))
    except Exception as error:
        message = str(error) if args.command == "snapshot" or isinstance(error, ValueError) \
            else "Wallpaper Engine controls are unavailable"
        print(json.dumps({"ok": False, "error": message}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
