"""Read-only discovery regressions. No Windows API, profile or process access."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "wallpaperengine_bridge", Path(__file__).with_name("bridge.py")
)
bridge = importlib.util.module_from_spec(spec)
# Only the registry import is Windows-specific at module load time. All OS
# entry points below are replaced, so these tests also run safely on macOS.
with patch.dict(sys.modules, {"winreg": types.ModuleType("winreg")}):
    spec.loader.exec_module(bridge)


class SnapshotTests(unittest.TestCase):
    def test_catalogue_failure_keeps_independent_process_state(self):
        for active in (False, True):
            for status_only in (False, True):
                for error in (ValueError("partial JSON"), PermissionError("locked"), KeyError("file")):
                    with self.subTest(active=active, status_only=status_only, error=type(error)):
                        with patch.object(bridge, "running", return_value=active), patch.object(
                            bridge, "catalog_snapshot", side_effect=error
                        ):
                            result = bridge.snapshot(status_only)
                        self.assertTrue(result["ok"])
                        self.assertIs(result["running"], active)
                        self.assertTrue(result["discoveryError"])
                        self.assertNotIn("monitors", result)  # Do not erase the last good catalogue.

    def test_process_failure_does_not_invent_an_absent_engine(self):
        with patch.object(bridge, "running", side_effect=OSError("process scan unavailable")), patch.object(
            bridge, "catalog_snapshot"
        ) as catalog:
            with self.assertRaises(OSError):
                bridge.snapshot()
            catalog.assert_not_called()

    def test_success_preserves_snapshot_contract(self):
        for status_only in (False, True):
            expected = {"ok": True, "running": True, "detected": True, "active": {"Monitor1": "project"}}
            with patch.object(bridge, "running", return_value=True), patch.object(
                bridge, "catalog_snapshot", return_value=expected
            ) as catalog:
                self.assertIs(bridge.snapshot(status_only), expected)
                catalog.assert_called_once_with(True, status_only)

    def test_missing_steam_still_reports_a_running_external_owner(self):
        with patch.object(bridge, "running", return_value=True), patch.object(
            bridge, "libraries", side_effect=FileNotFoundError()
        ):
            result = bridge.snapshot()
        self.assertTrue(result["running"])
        self.assertFalse(result["detected"])
        self.assertEqual(result["monitors"], {})

    def test_status_snapshot_resolves_selected_projects(self):
        # The config watcher's fast path must carry the active projects, not
        # just their config paths, so a wallpaper change can skip the
        # workshop-wide catalogue walk.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project_dir = root / "steamapps/workshop/content/431960/100"
            project_dir.mkdir(parents=True)
            (project_dir / "preview.jpg").write_bytes(b"preview")
            (project_dir / "project.json").write_text(
                json.dumps({"title": "Fixture", "preview": "preview.jpg"}), encoding="utf-8"
            )
            install_dir = root / "steamapps/common/Wallpaper Engine"
            install_dir.mkdir(parents=True)
            (install_dir / "wallpaper64.exe").write_bytes(b"")
            (install_dir / "config.json").write_text(
                json.dumps({
                    "tester": {
                        "general": {
                            "wallpaperconfig": {
                                "selectedwallpapers": {
                                    "Monitor0": {"file": str(project_dir / "project.json")},
                                    "Monitor1": {"file": str(root / "missing/project.json")},
                                }
                            }
                        }
                    }
                }),
                encoding="utf-8",
            )
            with patch.object(bridge, "libraries", return_value=[root]), patch.object(
                bridge, "install", return_value=install_dir
            ), patch.object(bridge, "running", return_value=True), patch.object(
                bridge.os, "getlogin", return_value="tester"
            ):
                result = bridge.snapshot(status_only=True)
                full = bridge.snapshot(status_only=False)

        self.assertTrue(result["ok"])
        self.assertTrue(result["detected"])
        self.assertEqual(result["active"], {
            "Monitor0": str(project_dir / "project.json"),
            "Monitor1": str(root / "missing/project.json"),
        })
        self.assertEqual(result["monitors"]["Monitor0"]["title"], "Fixture")
        self.assertEqual(result["monitors"]["Monitor0"]["preview"], (project_dir / "preview.jpg").resolve().as_posix())
        # A broken selection keeps its monitor key so the shell can fall back
        # instead of applying the previous project's palette indefinitely.
        self.assertEqual(result["monitors"]["Monitor1"], {
            "path": "", "preview": "", "title": "", "engine": True,
        })
        self.assertEqual(full["monitors"], result["monitors"])


if __name__ == "__main__":
    unittest.main()
