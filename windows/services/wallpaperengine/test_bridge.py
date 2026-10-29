"""Read-only discovery regressions. No Windows API, profile or process access."""

import importlib.util
from pathlib import Path
import sys
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


if __name__ == "__main__":
    unittest.main()
