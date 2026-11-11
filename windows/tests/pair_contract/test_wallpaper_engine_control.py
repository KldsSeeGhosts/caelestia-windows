"""Exercise CLI dispatch with every discovery/process boundary mocked."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
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

    def test_status_after_stop_play_reports_process_liveness_not_playback(self):
        # No native scan or WE command escapes these mocks. stop/play keep
        # wallpaper64.exe alive and reuse its window. The status API has no
        # "stopped" playback state that could suppress native discovery.
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "config.json").write_text(
                '{"fixture-user": {"general": {"wallpaperconfig": '
                '{"selectedwallpapers": {}}}}}', encoding="utf-8")
            with patch.object(self.bridge, "libraries", return_value=[]), \
                 patch.object(self.bridge, "install", return_value=directory), \
                 patch.object(self.bridge, "running_executable", return_value="wallpaper64.exe"), \
                 patch.object(Path, "is_file", return_value=True), \
                 patch.object(self.bridge.subprocess, "run") as run:
                for action in ("stop", "play"):
                    self.bridge.control_desktop(action)
                    for status_only in (True, False):
                        status = self.bridge.snapshot(status_only=status_only)
                        self.assertTrue(status["ok"])
                        self.assertTrue(status["running"])
                        self.assertTrue(status["detected"])
                    self.assertEqual(action, run.call_args.args[0][-1])
                self.assertEqual(2, run.call_count)


@unittest.skipUnless(os.name == "nt", "Windows-only bridge imports winreg")
class WallpaperEngineOpenTests(unittest.TestCase):
    """A selection validates only its own workshop project, not the catalogue."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "wallpaper_bridge", ROOT / "windows/services/wallpaperengine/bridge.py")
        self.bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bridge)
        self.env = patch.dict(os.environ, {
            "CAELESTIA_COMBINED_LIVE": "1", "CAELESTIA_SHELL_SMOKE": "0"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def make_library(self, root):
        library = root / "steam-library"
        workshop = library / "steamapps/workshop/content/431960"
        workshop.mkdir(parents=True)
        return library, workshop

    def make_project(self, directory, title="Fixture"):
        directory.mkdir(parents=True)
        (directory / "project.json").write_text(
            '{"title": "%s"}' % title, encoding="utf-8")
        return directory / "project.json"

    def make_install(self, root):
        install = root / "Wallpaper Engine"
        install.mkdir()
        (install / "wallpaper64.exe").write_bytes(b"")
        return install

    def test_monitor_selection_does_not_rebuild_the_catalogue(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            project = self.make_project(workshop / "12345")
            install = self.make_install(root)
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge, "snapshot") as snapshot, \
                 patch.object(self.bridge.subprocess, "run") as run:
                self.bridge.open_wallpaper(str(project), 1, None)
                snapshot.assert_not_called()
                self.assertEqual(
                    [(install / "wallpaper64.exe").as_posix(), "-control", "openWallpaper",
                     "-file", str(project.resolve()), "-monitor", "1"],
                    run.call_args.args[0])
                self.assertTrue(run.call_args.kwargs["check"])
                self.assertEqual(15, run.call_args.kwargs["timeout"])

    def test_screen_target_reads_config_for_location_mapping(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            project = self.make_project(workshop / "12345")
            install = self.make_install(root)
            display = self.bridge.display_id("monitor-path")
            (install / "config.json").write_text(
                '{"fixture-user": {"general": {"wallpaperconfig": '
                '{"selectedwallpapers": {"monitor-path": {"file": "C:/we/project.json"}}}}}}',
                encoding="utf-8")
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge, "active_display_ids", return_value={display}), \
                 patch.object(self.bridge, "snapshot") as snapshot, \
                 patch.object(self.bridge.subprocess, "run") as run:
                self.bridge.open_wallpaper(str(project), None, display)
                snapshot.assert_not_called()
                self.assertEqual(
                    [(install / "wallpaper64.exe").as_posix(), "-control", "openWallpaper",
                     "-file", str(project.resolve()), "-location", "monitor-path"],
                    run.call_args.args[0])

    def test_project_outside_every_workshop_location_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, _workshop = self.make_library(root)
            outside = self.make_project(root / "outside" / "12345")
            install = self.make_install(root)
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge, "snapshot") as snapshot, \
                 patch.object(self.bridge.subprocess, "run") as run:
                with self.assertRaisesRegex(
                        ValueError, "^project is not in the discovered workshop catalog$"):
                    self.bridge.open_wallpaper(str(outside), 0, None)
                snapshot.assert_not_called()
                run.assert_not_called()

    def test_all_displays_resolves_every_physical_target_before_dispatch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            project = self.make_project(workshop / "12345")
            install = self.make_install(root)
            general = {"wallpaperconfig": {"selectedwallpapers": {
                "display-one": {}, "display-two": {}}}}
            active = {self.bridge.display_id(name) for name in ("display-one", "display-two")}
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge, "read_json", return_value={"user": {"general": general}}), \
                 patch.object(self.bridge, "active_display_ids", return_value=active), \
                 patch.object(self.bridge.subprocess, "run") as run:
                self.bridge.open_wallpaper(str(project), None, None, all_displays=True)
                self.assertEqual(2, run.call_count)
                self.assertEqual({"display-one", "display-two"},
                                 {call.args[0][-1] for call in run.call_args_list})
                for call in run.call_args_list:
                    self.assertEqual("-location", call.args[0][-2])
                    self.assertGreater(call.kwargs["timeout"], 0)
                    self.assertLessEqual(call.kwargs["timeout"], 15)
                run.reset_mock()
                # A connected but unmapped display must reject the whole
                # request, not change the first display and then fail.
                active.add(self.bridge.display_id("unmapped"))
                with self.assertRaisesRegex(ValueError, "no unambiguous mapping"):
                    self.bridge.open_wallpaper(str(project), None, None, all_displays=True)
                run.assert_not_called()

    def test_display_summary_uses_native_ids_and_managed_locations(self):
        project = {"path": "C:/we/project.json", "title": "Fixture"}
        direct = self.bridge.display_projects({}, {"display-one": project})
        self.assertEqual(project, direct[self.bridge.display_id("display-one")])
        general = {"user": {"monitordetection": "managed",
                            "monitormap": {"display-two": {"location": 9}}}}
        managed = self.bridge.display_projects(general, {"Monitor9": project})
        self.assertEqual(project, managed[self.bridge.display_id("display-two")])

    def test_traversal_and_nested_project_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            self.make_project(workshop / "12345")
            nested = self.make_project(workshop / "12345" / "nested")
            outside = self.make_project(root / "outside" / "12345")
            escaped = (workshop / "12345" / ".." / ".." / ".." / ".." / ".." / ".."
                       / "outside" / "12345" / "project.json")
            install = self.make_install(root)
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge.subprocess, "run") as run:
                for candidate in (nested, escaped):
                    with self.subTest(candidate=candidate), \
                         self.assertRaisesRegex(
                             ValueError, "^project is not in the discovered workshop catalog$"):
                        self.bridge.open_wallpaper(str(candidate), 0, None)
                self.assertEqual(outside.resolve(), escaped.resolve())
                run.assert_not_called()

    def test_stopped_engine_is_never_launched(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            project = self.make_project(workshop / "12345")
            install = self.make_install(root)
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=False), \
                 patch.object(self.bridge.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "^Wallpaper Engine is not running$"):
                    self.bridge.open_wallpaper(str(project), 0, None)
                run.assert_not_called()

    def test_unreadable_screen_config_is_reported_without_a_private_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            library, workshop = self.make_library(root)
            project = self.make_project(workshop / "12345")
            install = self.make_install(root)
            (install / "config.json").write_text("{", encoding="utf-8")
            with patch.object(self.bridge, "libraries", return_value=[library]), \
                 patch.object(self.bridge, "install", return_value=install), \
                 patch.object(self.bridge, "running", return_value=True), \
                 patch.object(self.bridge.subprocess, "run") as run:
                with self.assertRaisesRegex(
                        ValueError, "^Wallpaper Engine configuration is unavailable$"):
                    self.bridge.open_wallpaper(str(project), None, "a" * 64)
                run.assert_not_called()
