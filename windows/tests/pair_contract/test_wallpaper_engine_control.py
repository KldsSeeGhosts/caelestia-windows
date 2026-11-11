"""Exercise CLI dispatch with every discovery/process boundary mocked."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "nt", "Windows-only bridge imports winreg")
class WallpaperEngineControlTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "wallpaper_bridge", ROOT / "windows/services/wallpaperengine/bridge.py")
        self.bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bridge)
        self.env = patch.dict(os.environ, {
            "CAELESTIA_COMBINED_LIVE": "1", "CAELESTIA_SHELL_SMOKE": "0"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_stop_and_play_use_running_architecture_and_all_displays(self):
        for name in ("wallpaper32.exe", "wallpaper64.exe"):
            for action in ("stop", "play"):
                with self.subTest(name=name, action=action), \
                     patch.object(self.bridge, "libraries", return_value=[]), \
                     patch.object(self.bridge, "install", return_value=Path("C:/fake WE")), \
                     patch.object(self.bridge, "running_executable", return_value=name), \
                     patch.object(Path, "is_file", return_value=True), \
                     patch.object(self.bridge.subprocess, "run") as run:
                    self.bridge.control_desktop(action)
                    self.assertEqual([f"C:/fake WE/{name}", "-control", action],
                                     run.call_args.args[0])
                    self.assertTrue(run.call_args.kwargs["check"])
                    self.assertEqual(15, run.call_args.kwargs["timeout"])
                    self.assertEqual(subprocess.CREATE_NO_WINDOW,
                                     run.call_args.kwargs["creationflags"])

    def test_write_gates_and_unknown_commands_never_discover_or_launch(self):
        for live, smoke, action in (("0", "0", "stop"), ("1", "1", "play"),
                                    ("1", "0", "exit")):
            with patch.dict(os.environ, {"CAELESTIA_COMBINED_LIVE": live,
                                        "CAELESTIA_SHELL_SMOKE": smoke}), \
                 patch.object(self.bridge, "libraries") as discover, \
                 patch.object(self.bridge.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    self.bridge.control_desktop(action)
                discover.assert_not_called()
                run.assert_not_called()

    def test_absent_or_stopped_engine_is_never_launched(self):
        for directory, executable in ((None, "wallpaper64.exe"), (Path("C:/fake"), "")):
            with patch.object(self.bridge, "libraries", return_value=[]), \
                 patch.object(self.bridge, "install", return_value=directory), \
                 patch.object(self.bridge, "running_executable", return_value=executable), \
                 patch.object(self.bridge.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "not running"):
                    self.bridge.control_desktop("stop")
                run.assert_not_called()

    def test_dispatch_failures_are_sanitized_and_not_retried(self):
        with patch.object(self.bridge, "libraries", return_value=[]), \
             patch.object(self.bridge, "install", return_value=Path("C:/fake")), \
             patch.object(self.bridge, "running_executable", return_value="wallpaper64.exe"), \
             patch.object(Path, "is_file", return_value=True), \
             patch.object(self.bridge.subprocess, "run",
                          side_effect=OSError("private path")) as run:
            with self.assertRaisesRegex(ValueError, "^Wallpaper Engine could not change desktop playback$"):
                self.bridge.control_desktop("stop")
            self.assertEqual(1, run.call_count)
