"""Regression tests for warning baseline parsing, classification and checking."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "windows/tools/warning_baseline.py"
FIXTURE = Path(__file__).resolve().parent / "fixtures/warning-baseline.log"

spec = importlib.util.spec_from_file_location("warning_baseline", TOOL)
warning_baseline = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = warning_baseline
spec.loader.exec_module(warning_baseline)


class WarningBaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="warning-baseline-",
            dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"),
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / "build"
        self.qt = self.root / "Tools" / "Qt" / "6.11.3" / "msvc2022_64"
        self.baseline = self.root / "baseline.json"

    def write_log(self, name="build.log", extra=""):
        text = FIXTURE.read_text(encoding="utf-8").format(
            repo=ROOT, build=self.build, qt=self.qt
        )
        path = self.root / name
        path.write_text(text + extra, encoding="utf-8")
        return path

    def run_tool(self, *arguments):
        return subprocess.run(
            [sys.executable, "-B", str(TOOL), *map(str, arguments)],
            capture_output=True,
            text=True,
            timeout=60,
        )

    def generate(self, log):
        result = self.run_tool(
            "--log", log, "--baseline", self.baseline,
            "--repo-root", ROOT, "--build-root", self.build,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return json.loads(self.baseline.read_text(encoding="utf-8"))

    def test_parses_normalizes_and_counts_repeated_output(self):
        report = self.generate(self.write_log())
        counts = report["counts"]
        self.assertEqual(12, counts["rawWarningLines"])
        self.assertEqual(8, counts["uniqueDiagnostics"])
        self.assertEqual(1, counts["ownedUniqueDiagnostics"])
        self.assertEqual(
            {
                "shell-plugin": {"rawWarningLines": 3, "uniqueDiagnostics": 2},
                "m3shapes": {"rawWarningLines": 4, "uniqueDiagnostics": 2},
                "backend": {"rawWarningLines": 2, "uniqueDiagnostics": 1},
                "qt-headers": {"rawWarningLines": 1, "uniqueDiagnostics": 1},
                "other-third-party": {"rawWarningLines": 2, "uniqueDiagnostics": 2},
            },
            counts["components"],
        )
        self.assertEqual(
            {"rawWarningLines": 3, "uniqueDiagnostics": 1},
            counts["flags"]["-Wc++98-compat"],
        )
        self.assertEqual(3, counts["flags"]["-Wdeprecated-declarations"]["rawWarningLines"])
        self.assertEqual(2, counts["flags"]["-Wdeprecated-declarations"]["uniqueDiagnostics"])
        self.assertEqual({"id": "windows-x64-v1",
                          "compiler": "clang-cl 20.1.8 (x86_64-pc-windows-msvc)",
                          "qtVersion": "6.11.3",
                          "windowsSdkVersion": "10.0.26100.0",
                          "vcToolsVersion": "14.44.35207"}, report["toolchain"])

    def test_normalizes_repository_build_and_dependency_locations(self):
        cases = (
            (f"{ROOT}\\windows\\deps\\m3shapes\\src\\qml\\..\\core\\Point.hpp(11,13)",
             "windows/deps/m3shapes/src/core/Point.hpp"),
            ("C:/repo/windows/deps/quickshell/src/windows\\screen_identity.cpp(356,43)",
             "windows/deps/quickshell/src/windows/screen_identity.cpp"),
            (f"{self.qt}\\include\\QtCore\\qstring.h(1,1)",
             "qt/include/QtCore/qstring.h"),
            (f"{self.build}\\caelestia\\generated.cpp(5,1)",
             "<build>/caelestia/generated.cpp"),
            ("plugin/src/Caelestia/cutils.cpp:8:2",
             "plugin/src/Caelestia/cutils.cpp"),
        )
        for location, expected in cases:
            diagnostic = warning_baseline.parse_line(
                f"{location}: warning: fixture [-Wdeprecated-declarations]",
                ROOT, self.build,
            )
            self.assertIsNotNone(diagnostic, location)
            self.assertEqual(expected, diagnostic.file)
            self.assertNotIn(str(ROOT).casefold(), diagnostic.file.casefold())

    def test_imported_and_owned_code_are_separate(self):
        report = self.generate(self.write_log())
        self.assertEqual(
            [{
                "file": "plugin/src/Caelestia/cutils.cpp",
                "line": 178,
                "column": 31,
                "flag": "-Wdeprecated-declarations",
                "message": "'match' is deprecated: Use matchView instead.",
            }],
            report["ownedDiagnostics"],
        )
        self.assertEqual("other-third-party", warning_baseline.classify("plugin/3rdparty/rgbcx/rgbcx.cpp"))
        self.assertEqual("m3shapes", warning_baseline.classify("windows/deps/m3shapes/src/core/Point.hpp"))
        self.assertEqual("backend", warning_baseline.classify("windows/deps/quickshell/src/windows/panel.cpp"))
        self.assertEqual("qt-headers", warning_baseline.classify("qt/include/QtCore/qstring.h"))
        self.assertEqual("other-third-party", warning_baseline.classify("cli11/CLI/CLI.hpp"))
        self.assertEqual("shell-plugin", warning_baseline.classify("<build>/caelestia/generated.cpp"))

    def test_check_rejects_new_owned_warning_and_accepts_known_output(self):
        log = self.write_log()
        self.generate(log)
        arguments = ("--check", log, "--baseline", self.baseline,
                     "--repo-root", ROOT, "--build-root", self.build)
        passed = self.run_tool(*arguments)
        self.assertEqual(0, passed.returncode, passed.stdout + passed.stderr)
        self.assertIn("all present", passed.stdout)

        new_owned = (
            f"{ROOT}\\plugin\\src\\Caelestia\\newfile.cpp(42,9): "
            "warning: deliberately introduced [-Wunused-variable]\n"
        )
        failed = self.run_tool(*(
            "--check", self.write_log("new-owned.log", new_owned),
            "--baseline", self.baseline, "--repo-root", ROOT,
            "--build-root", self.build,
        ))
        self.assertEqual(1, failed.returncode, failed.stdout + failed.stderr)
        self.assertIn("new owned warning", failed.stdout)
        self.assertIn("plugin/src/Caelestia/newfile.cpp(42,9)", failed.stdout)

        new_imported = (
            f"{ROOT}\\windows\\deps\\m3shapes\\src\\core\\New.hpp(1,1): "
            "warning: imported only [-Wc++98-compat]\n"
        )
        imported = self.run_tool(*(
            "--check", self.write_log("new-imported.log", new_imported),
            "--baseline", self.baseline, "--repo-root", ROOT,
            "--build-root", self.build,
        ))
        self.assertEqual(0, imported.returncode, imported.stdout + imported.stderr)

    def test_check_requires_a_refreshed_toolchain_baseline(self):
        log = self.write_log()
        report = self.generate(log)
        report["toolchain"]["qtVersion"] = "0.0.0"
        self.baseline.write_text(json.dumps(report) + "\n", encoding="utf-8")
        result = self.run_tool(
            "--check", log, "--baseline", self.baseline,
            "--repo-root", ROOT, "--build-root", self.build,
        )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("does not match windows/toolchain.json", result.stderr)


if __name__ == "__main__":
    unittest.main()
